from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4
import hmac
from sqlalchemy import func, select
from app.core.errors import AppError
from app.modules.wallet.models import Deposit, DepositAddress, WalletControl, WalletLedgerEntry, WalletLedgerTransaction, WalletWebhookEvent, Withdrawal
from app.modules.wallet.safety import WalletSafetyMixin, precise_amount, audit_write, usdt_liability
from app.modules.wallet.models import WalletPayoutIntent, WalletSafetyState, WalletWithdrawalAuthorization
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.receipt_models import DepositReceipt
from app.modules.ledger.reserve import lock_budget, require_coverage
import hashlib
import json
USDT = Decimal("0.000001")
MINIMUM_TRANSFER = Decimal("10.000000")
def usdt(value): return Decimal(value).quantize(USDT, rounding=ROUND_HALF_UP)

# 提现状态机（F05）：单向推进；FAILED 已补偿为终态。
WITHDRAWAL_TERMINAL = {"CHAIN_CONFIRMED", "FAILED_COMPENSATED", "CANCELLED"}

class WalletLedger:
    reserve_policy = 'full_backing'
    def __init__(self, session_factory): self.factory = session_factory
    def post(self, *, entries, actor_id, reason_code, idempotency_key, scope, session=None):
        normalized={k:usdt(v) for k,v in entries.items() if usdt(v)!=0}
        if not normalized or sum(normalized.values(), Decimal("0")) != Decimal("0"): raise ValueError("wallet ledger entries must be balanced")
        now=datetime.now(timezone.utc)
        if session is not None:
            return self._post(session, normalized, actor_id, reason_code, idempotency_key, scope, now)
        with self.factory.begin() as owned:
            return self._post(owned, normalized, actor_id, reason_code, idempotency_key, scope, now)

    def _post(self, session, normalized, actor_id, reason_code, idempotency_key, scope, now):
        if not actor_id or not reason_code or not idempotency_key:
            raise ValueError('actor, reason and idempotency required')
        reserve = lock_budget(session)
        # F04：重复键必须核验分录内容——同键不同载荷是冲突，不得静默返回。
        existing=session.scalar(select(WalletLedgerTransaction).where(WalletLedgerTransaction.scope==scope, WalletLedgerTransaction.idempotency_key==idempotency_key))
        if existing:
            persisted={row.account_id:usdt(row.amount) for row in session.scalars(select(WalletLedgerEntry).where(WalletLedgerEntry.transaction_id==existing.id))}
            if persisted != normalized or existing.actor_id != actor_id or existing.reason_code != reason_code:
                raise ValueError("wallet ledger idempotency key reused with different payload")
            return existing
        liability_delta = sum((delta for account, delta in normalized.items() if account not in {'PLATFORM_CUSTODY', 'PLATFORM_CONVERSION'}), Decimal('0'))
        if liability_delta > 0:
            require_coverage(session, reserve, usdt_delta=liability_delta, policy=self.reserve_policy)
        from app.modules.ledger.account_locks import lock_accounts
        lock_accounts(session, [a for a,d in normalized.items() if d < 0], asset="USDT-TRC20")
        for account,delta in normalized.items():
            if delta < 0 and account not in {'PLATFORM_CUSTODY', 'PLATFORM_CONVERSION'}:
                current=session.scalar(select(func.coalesce(func.sum(WalletLedgerEntry.amount),0)).where(WalletLedgerEntry.account_id==account, WalletLedgerEntry.asset=="USDT-TRC20"))
                if usdt(Decimal(current))+delta < 0: raise ValueError("insufficient USDT balance")
        tx=WalletLedgerTransaction(id=str(uuid4()),asset="USDT-TRC20",scope=scope,idempotency_key=idempotency_key,actor_id=actor_id,reason_code=reason_code,created_at=now); session.add(tx); session.flush()
        for account,amount in normalized.items(): session.add(WalletLedgerEntry(id=str(uuid4()),transaction_id=tx.id,account_id=account,asset="USDT-TRC20",amount=amount,created_at=now))
        if reserve is not None:
            reserve.usdt_liability += liability_delta
            reserve.version += 1
        audit_write(session, actor_id, tx.id, 'wallet.ledger_posted', reason_code)
        session.flush(); return tx

    def balance(self, account_id):
        with self.factory() as session: return usdt(Decimal(session.scalar(select(func.coalesce(func.sum(WalletLedgerEntry.amount),0)).where(WalletLedgerEntry.account_id==account_id, WalletLedgerEntry.asset=="USDT-TRC20"))))

    def require_conversion_release(self, *, session, user_id, conversion_id, release_id, amount):
        """Public proof for an exact conversion rollback, never a raw ledger read by callers."""
        from app.modules.wallet.models import WalletConversion
        original = session.get(WalletConversion, conversion_id)
        release = session.get(WalletLedgerTransaction, release_id)
        if (original is None or original.user_id != user_id or original.direction != 'CAIBI_TO_USDT'
                or original.status != 'COMPLETED' or original.source_amount != amount or original.target_amount != amount
                or not original.idempotency_key.startswith('payout:')
                or release is None or release.actor_id != user_id or release.scope != 'wallet.conversion_reversal'
                or release.reason_code != 'MANUAL_PAYOUT_CANCELLED' or release.idempotency_key != 'reverse:'+conversion_id):
            raise ValueError('conversion release proof invalid')
        entries = {entry.account_id: entry.amount for entry in session.scalars(select(WalletLedgerEntry).where(
            WalletLedgerEntry.transaction_id == release_id))}
        if entries != {user_id: -amount, 'PLATFORM_CONVERSION': amount}:
            raise ValueError('conversion release amount mismatch')

class WalletService(WalletSafetyMixin):
    def __init__(self, session_factory, provider, *, withdrawal_admin_threshold=Decimal("1000.000000"), confirmation_threshold=20, conversions_enabled=False, manual_runtime=None):
        self.factory=session_factory; self.provider=provider; self.wallet_ledger=WalletLedger(session_factory); self.admin_threshold=usdt(withdrawal_admin_threshold); self.confirmation_threshold=confirmation_threshold
        self.confirmation_threshold = max(20, int(confirmation_threshold))
        self.conversions_enabled = bool(conversions_enabled)
        self.manual_runtime = manual_runtime
        self.reserve_policy = manual_runtime.receipts.reserve_policy if manual_runtime is not None else 'full_backing'
        self.wallet_ledger.reserve_policy = self.reserve_policy
        if self.conversions_enabled and manual_runtime is None:
            self._offline_provider()
    def usdt_balance(self,user_id): return self.wallet_ledger.balance(user_id)
    def config(self) -> dict:
        """U03：钱包有效规则（网络/确认阈值），客户端统一展示来源。"""
        return {"asset": "USDT-TRC20", "network": "TRC20", "confirmation_threshold": self.confirmation_threshold, "min_deposit": str(MINIMUM_TRANSFER), "min_withdrawal": str(MINIMUM_TRANSFER), "decimals": 6}
    def deposit_address(self, user_id: str) -> str:
        """A01：地址获取/分配——已分配直接复用（跨用户隔离按 user_id 唯一），
        未分配调用托管方并持久化归属。"""
        self._offline_provider()
        with self.factory() as session:
            self._check_user(session, user_id)
            existing = session.scalar(select(DepositAddress).where(DepositAddress.user_id == user_id))
            if existing: return existing.address
        address = self.provider.create_deposit_address(user_id)
        if not address: raise ValueError("custody failed to allocate deposit address")
        with self.factory.begin() as session:
            existing = session.scalar(select(DepositAddress).where(DepositAddress.user_id == user_id))
            if existing: return existing.address
            session.add(DepositAddress(id=str(uuid4()), user_id=user_id, asset="USDT-TRC20", address=address, created_at=datetime.now(timezone.utc)))
            session.flush()
            return address
    def withdrawal_status(self, withdrawal_id: str, user_id: str):
        with self.factory() as session:
            row = session.get(Withdrawal, withdrawal_id)
            if row is None or row.user_id != user_id: raise ValueError("withdrawal not found")
            return {"id": row.id, "status": row.status, "amount": str(row.amount), "address": row.address, "client_order_id": row.client_order_id, "txid": row.provider_txid}
    def history(self, user_id: str, kind: str | None = None, *, limit: int = 50, cursor: tuple | None = None):
        """F07：稳定游标分页（created_at,id 组合键，DB 侧有界检索）。"""
        limit = max(1, min(int(limit), 100))
        with self.factory() as session:
            items: list[tuple[datetime, str, dict]] = []
            if kind in (None, "deposit"):
                query = select(Deposit).where(Deposit.user_id == user_id)
                if cursor is not None:
                    query = query.where((Deposit.created_at < cursor[0]) | ((Deposit.created_at == cursor[0]) & (Deposit.id < cursor[1])))
                for r in session.scalars(query.order_by(Deposit.created_at.desc(), Deposit.id.desc()).limit(limit + 1)):
                    items.append((r.created_at, r.id, {"id": r.id, "kind": "deposit", "amount": str(r.amount), "status": r.status, "created_at": r.created_at}))
            if kind in (None, "withdrawal"):
                query = select(Withdrawal).where(Withdrawal.user_id == user_id)
                if cursor is not None:
                    query = query.where((Withdrawal.created_at < cursor[0]) | ((Withdrawal.created_at == cursor[0]) & (Withdrawal.id < cursor[1])))
                for r in session.scalars(query.order_by(Withdrawal.created_at.desc(), Withdrawal.id.desc()).limit(limit + 1)):
                    items.append((r.created_at, r.id, {"id": r.id, "kind": "withdrawal", "amount": str(r.amount), "status": r.status, "created_at": r.created_at}))
            for model, timestamp, entry_kind in ((ManualPayoutOrder, ManualPayoutOrder.created_at, 'withdrawal'),
                    (DepositReceipt, DepositReceipt.observed_at, 'deposit')):
                if kind not in (None, entry_kind):
                    continue
                query = select(model).where(model.user_id == user_id)
                if cursor is not None:
                    query = query.where((timestamp < cursor[0]) | ((timestamp == cursor[0]) & (model.id < cursor[1])))
                for row in session.scalars(query.order_by(timestamp.desc(), model.id.desc()).limit(limit+1)):
                    created = row.created_at if model is ManualPayoutOrder else row.observed_at
                    items.append((created, row.id, dict(id=row.id, kind=entry_kind,
                        amount=str(row.amount) if row.amount is not None else None,
                        status=row.status, created_at=created)))
            items.sort(key=lambda x: (x[0], x[1]), reverse=True)
            page = items[:limit]
            next_cursor = f"{page[-1][0].isoformat()}|{page[-1][1]}" if len(items) > limit and page else None
            return [entry[2] for entry in page], next_cursor
    def credit_for_test(self,user_id,amount):
        self._offline_provider()
        amount = precise_amount(amount)
        return self.wallet_ledger.post(entries={user_id:amount,"PLATFORM_CUSTODY":-amount},actor_id="test",reason_code="TEST_CREDIT",idempotency_key=f"test-credit:{user_id}:{amount}",scope="wallet.deposit")

    # ------------------------------------------------------------------
    # 充值（F03）：事件接收记录（WalletWebhookEvent）与充值实体（Deposit）
    # 分离；按链上稳定身份 txid 聚合；确认数/状态单向推进；入账与
    # CREDITED 同一事务；同事件重放/新事件同 txid/入账前后崩溃均可恢复。
    # ------------------------------------------------------------------
    def handle_deposit_webhook(self,payload,signature):
        self._offline_provider()
        if not hmac.compare_digest(self.provider.sign(payload),signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID",message="托管回调签名无效",status_code=401)
        if payload.get("asset")!="USDT-TRC20" or payload.get("type")!="DEPOSIT_CONFIRMED": raise ValueError("unsupported custody event")
        event_id=payload["event_id"]; txid=payload["txid"]; now=datetime.now(timezone.utc)
        confirmations=int(payload["confirmations"])
        with self.factory.begin() as session:
            lock_budget(session)
            self._check_user(session, payload['user_id'])
            # 事件接收记录（重放幂等；已见过的事件继续完成未完成的流程，
            # 而不是直接返回）。
            seen = session.get(WalletWebhookEvent, event_id)
            if seen is None:
                session.add(WalletWebhookEvent(event_id=event_id, event_type="DEPOSIT_CONFIRMED", received_at=now))
                session.flush()
            # 按链上身份（txid）聚合：新事件同 txid 更新确认数而非撞唯一键。
            deposit = session.scalar(select(Deposit).where(Deposit.txid == txid).with_for_update())
            if deposit is None:
                deposit = Deposit(id=str(uuid4()), event_id=event_id, user_id=payload["user_id"], txid=txid, amount=precise_amount(payload["amount"]), confirmations=confirmations, status="PENDING", created_at=now)
                session.add(deposit); session.flush()
            else:
                if deposit.user_id != payload['user_id'] or deposit.amount != precise_amount(payload['amount']):
                    raise ValueError('deposit identity payload conflict')
                # 单向推进：确认数只增不减。
                deposit.confirmations = max(deposit.confirmations, confirmations)
            if deposit.status == "CREDITED":
                return "CREDITED"
            if deposit.status == 'MANUAL_REVIEW':
                return 'MANUAL_REVIEW'
            evidence = self.provider.deposit_evidence(txid)
            verified = self.provider.verify_finality(evidence, threshold=self.confirmation_threshold)
            if verified and (evidence.get('user_id') != deposit.user_id or Decimal(evidence.get('amount', '0')) != deposit.amount):
                raise ValueError('deposit evidence mismatch')
            if verified and deposit.amount < MINIMUM_TRANSFER:
                deposit.status = 'MANUAL_REVIEW'
                reserve = lock_budget(session)
                if reserve is not None:
                    session.flush()
                    reserve.usdt_liability = usdt_liability(session)
                    reserve.eligible_usdt = Decimal(self.provider.custody_balance)
                    reserve.observed_at = now
                    reserve.version += 1
                audit_write(session, 'custody-reconcile', deposit.id, 'wallet.deposit_manual_review', 'BELOW_DEPOSIT_MINIMUM')
                return deposit.status
            if verified and deposit.confirmations >= self.confirmation_threshold:
                # 余额入账与 CREDITED 状态同一事务；入账幂等键取链上身份。
                self.wallet_ledger.post(entries={deposit.user_id:deposit.amount,"PLATFORM_CUSTODY":-deposit.amount},actor_id="custody-webhook",reason_code="DEPOSIT_CONFIRMED",idempotency_key=f"deposit:{txid}",scope="wallet.deposit",session=session)
                deposit.status = "CREDITED"
                session.flush()
                return "CREDITED"
            session.flush()
            return "PENDING"

    def request_withdrawal(self, *, user_id, amount, address, client_order_id, reason_code):
        self._offline_provider()
        amount=precise_amount(amount)
        if amount<MINIMUM_TRANSFER or amount>100 or not address or not reason_code or not client_order_id: raise ValueError("invalid withdrawal request: sandbox range 10-100")
        now=datetime.now(timezone.utc)
        # F04：客户端键仅做"该用户"的请求去重；重复键核验规范化载荷。
        with self.factory.begin() as session:
            lock_budget(session)
            self._check_user(session, user_id)
            existing=session.scalar(select(Withdrawal).where(Withdrawal.user_id==user_id,Withdrawal.client_order_id==client_order_id).with_for_update())
            if existing:
                if usdt(existing.amount) != amount or existing.address != address:
                    raise ValueError("withdrawal client order id reused with different payload")
                return existing
            if self._paused(session):
                raise ValueError('withdrawals paused')
            from datetime import timedelta
            recent = select(Withdrawal).where(Withdrawal.created_at >= now-timedelta(hours=24), Withdrawal.status.notin_(['CANCELLED', 'FAILED_COMPENSATED']))
            rows = session.scalars(recent).all()
            if sum((r.amount for r in rows if r.user_id == user_id), Decimal('0')) + amount > 200 or sum((r.amount for r in rows), Decimal('0')) + amount > 500:
                raise ValueError('sandbox rolling withdrawal limit')
            row=Withdrawal(id=str(uuid4()),user_id=user_id,client_order_id=client_order_id,address=address,amount=amount,status="REQUESTED",created_at=now,updated_at=now)
            session.add(row)
            session.add(WalletWithdrawalAuthorization(withdrawal_id=row.id, request_digest=self._request_digest(row)))
            self.wallet_ledger.post(entries={user_id:-amount, f'HOLD:{user_id}':amount}, actor_id=user_id, reason_code=reason_code, idempotency_key=f'hold:{row.id}', scope='wallet.withdrawal', session=session)
            audit_write(session, user_id, row.id, 'wallet.withdrawal_requested', reason_code)
            session.flush()
            return row

    # ------------------------------------------------------------------
    # 提现回调（F04/F05）：按全局唯一订单 ID 定位；FAILED 与补偿分录同
    # 一事务；重复/乱序事件有确定结果。
    # ------------------------------------------------------------------
    def handle_withdrawal_webhook(self, payload, signature):
        self._offline_provider()
        if not hmac.compare_digest(self.provider.sign(payload), signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID", message="托管回调签名无效", status_code=401)
        if payload.get("asset") != "USDT-TRC20" or payload.get("type") != "WITHDRAWAL_STATUS": raise ValueError("unsupported custody event")
        event_id, status = payload["event_id"], payload["status"]
        if status not in {"CHAIN_CONFIRMED", "FAILED"}: raise ValueError("unsupported withdrawal status")
        with self.factory.begin() as session:
            lock_budget(session)
            event = session.get(WalletWebhookEvent, event_id)
            row = self._locate_withdrawal(session, payload.get("client_order_id"))
            if row is None: raise ValueError("withdrawal order not found")
            if event is None:
                session.add(WalletWebhookEvent(event_id=event_id, event_type="WITHDRAWAL_STATUS", received_at=datetime.now(timezone.utc)))
                session.flush()
            # 已终态：重复/乱序事件不再改变结果（补偿本身幂等）。
            if row.status in WITHDRAWAL_TERMINAL:
                return row.status
            # Callback is a wake-up hint. It never authorizes release/settlement.
            self._apply_provider_result(row, self.provider.get_withdrawal(row.id), session=session, actor_id='custody-reconcile')
            session.flush()
            return row.status

    @staticmethod
    def _locate_withdrawal(session, order_reference: str | None) -> Withdrawal | None:
        """F04：回调按全局唯一 Withdrawal.id 定位；兼容旧载荷（按客户端
        订单号）时若跨用户存在歧义则拒绝，绝不更新错误用户的订单。"""
        if not order_reference:
            return None
        row = session.get(Withdrawal, order_reference)
        if row is not None:
            return row
        legacy = session.scalars(select(Withdrawal).where(Withdrawal.client_order_id == order_reference)).all()
        if len(legacy) == 1:
            return legacy[0]
        return None

    def resolve_unknown_withdrawal(self, withdrawal_id: str, *, actor_id: str) -> Withdrawal:
        """F05：UNKNOWN 状态先查询托管结果再裁决——只有可证实的最终
        失败才补偿；托管仍 UNKNOWN/处理中绝不退款。"""
        self._offline_provider()
        with self.factory() as session:
            row = session.get(Withdrawal, withdrawal_id)
            if row is None: raise ValueError("withdrawal not found")
            result = self.provider.get_withdrawal(row.id)
        status = result.get("status")
        with self.factory.begin() as session:
            lock_budget(session)
            row = session.get(Withdrawal, withdrawal_id, with_for_update=True)
            if row.status in WITHDRAWAL_TERMINAL:
                return row
            self._apply_provider_result(row, result, session=session, actor_id=actor_id)
            session.flush()
            return row

    def _has_hold(self, row, session):
        return session.scalar(select(WalletLedgerTransaction).where(WalletLedgerTransaction.scope == 'wallet.withdrawal', WalletLedgerTransaction.idempotency_key == f'hold:{row.id}')) is not None

    @staticmethod
    def _request_digest(row):
        return hashlib.sha256(json.dumps({'id':row.id, 'user_id':row.user_id, 'address':row.address, 'amount':f'{row.amount:.6f}', 'network':'TRC20', 'contract':'SANDBOX_USDT_CONTRACT', 'fee_cap':'0.000000', 'policy':'sandbox-manual-v1'}, sort_keys=True).encode()).hexdigest()

    def _verify_request_digest(self, row, session):
        auth = session.get(WalletWithdrawalAuthorization, row.id)
        if auth is None or not hmac.compare_digest(auth.request_digest, self._request_digest(row)):
            raise ValueError('withdrawal approval digest mismatch')

    def _release_hold(self, row, *, session, actor_id, reason):
        self._verify_request_digest(row, session)
        if not self._has_hold(row, session):
            raise ValueError('legacy withdrawal requires manual hold reconstruction')
        self.wallet_ledger.post(entries={f'HOLD:{row.user_id}': -row.amount, row.user_id: row.amount}, actor_id=actor_id,
            reason_code=reason, idempotency_key=f'hold-release:{row.id}', scope='wallet.withdrawal', session=session)

    def _apply_provider_result(self, row, result, *, session, actor_id):
        if row.status not in {'SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN'}:
            return
        if not session.get(WalletPayoutIntent, row.id) or not self._has_hold(row, session):
            if row.status != 'UNKNOWN':
                audit_write(session, actor_id, row.id, 'wallet.withdrawal_unknown', 'LEGACY_HOLD_RECONSTRUCTION_REQUIRED')
            row.status = 'UNKNOWN'
            return
        self._verify_request_digest(row, session)
        if result.get('client_order_id') != row.id or result.get('address') != row.address or Decimal(result.get('amount', '0')) != row.amount:
            if row.status != 'UNKNOWN':
                audit_write(session, actor_id, row.id, 'wallet.withdrawal_unknown', 'CUSTODY_EVIDENCE_MISMATCH')
            row.status = 'UNKNOWN'
            return
        status = result.get('status')
        if status == 'FAILED' and result.get('terminal_non_execution') is True and result.get('independent_no_transfer') is True:
            self._release_hold(row, session=session, actor_id=actor_id, reason='WITHDRAWAL_FAILED_COMPENSATION')
            row.status = 'FAILED_COMPENSATED'
        elif status == 'CHAIN_CONFIRMED' and self.provider.verify_finality(result, threshold=self.confirmation_threshold):
            self.wallet_ledger.post(entries={f'HOLD:{row.user_id}': -row.amount, 'PLATFORM_CUSTODY': row.amount}, actor_id=actor_id,
                reason_code='WITHDRAWAL_SETTLED', idempotency_key=f'hold-consume:{row.id}', scope='wallet.withdrawal', session=session)
            row.status = 'CHAIN_CONFIRMED'
        else:
            row.status = 'UNKNOWN' if status == 'UNKNOWN' else row.status
            return
        row.provider_txid = result.get('txid')
        row.updated_at = datetime.now(timezone.utc)
        reserve = lock_budget(session)
        if reserve is not None:
            reserve.pending_payouts = max(0, reserve.pending_payouts - 1)
            reserve.eligible_usdt = Decimal(self.provider.custody_balance)
            reserve.observed_at = datetime.now(timezone.utc)
            reserve.version += 1
        audit_write(session, actor_id, row.id, 'wallet.withdrawal_finalized', row.status)

    def reconcile_incremental(self, *, actor_id: str):
        return self._reconcile(actor_id=actor_id, mode="INCREMENTAL")

    def reconcile_full(self, *, actor_id: str):
        return self._reconcile(actor_id=actor_id, mode="FULL")

    def _reconcile(self, *, actor_id: str, mode: str):
        self._offline_provider()
        with self.factory() as session:
            from app.modules.ledger.service import LedgerService
            expected = usdt(usdt_liability(session) + LedgerService(self.factory).redeemable_liability(session=session))
        actual = usdt(self.provider.custody_balance)
        matched = actual >= expected
        if not matched: self.pause_on_reconciliation_mismatch(f"{mode}: custody={actual} internal={expected}")
        return ReconciliationResult(mode=mode, expected=expected, actual=actual, matched=matched)
    def finance_approve(self,id,approver_id): return self._approve(id,approver_id,"finance_approver_id","REQUESTED","FINANCE_APPROVED")
    def admin_approve(self,id,approver_id):
        return self._approve(id,approver_id,'admin_approver_id','FINANCE_APPROVED','ADMIN_APPROVED')
    def _approve(self,id,approver,field,expected,status):
        with self.factory.begin() as s:
            lock_budget(s)
            row=s.get(Withdrawal,id, with_for_update=True)
            if not row or row.status!=expected: raise ValueError("illegal withdrawal approval transition")
            if not approver or row.user_id == approver: raise ValueError('self approval forbidden')
            self._verify_request_digest(row, s)
            self._check_user(s, row.user_id)
            if self._paused(s): raise ValueError('withdrawals paused')
            if not self._has_hold(row, s): raise ValueError('legacy withdrawal requires manual hold reconstruction')
            if field=="admin_approver_id" and row.finance_approver_id==approver: raise ValueError("two approvers required")
            audit_write(s, approver, row.id, 'wallet.withdrawal_approved', status)
            setattr(row,field,approver); row.status=status; row.updated_at=datetime.now(timezone.utc); s.flush(); return row
    def submit_to_custody(self,id,actor_id):
        provider = self._offline_provider()
        with self.factory.begin() as s:
            reserve = lock_budget(s)
            row=s.get(Withdrawal,id, with_for_update=True)
            if not row: raise ValueError("withdrawal not found")
            if row.status in {'SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN'} or row.status in WITHDRAWAL_TERMINAL: return row
            if row.status != 'ADMIN_APPROVED' or not row.finance_approver_id or row.finance_approver_id == row.admin_approver_id: raise ValueError("withdrawal requires two approvers")
            self._verify_request_digest(row, s)
            if self._paused(s): raise ValueError("withdrawals paused")
            self._check_user(s, row.user_id)
            if not self._has_hold(row, s): raise ValueError('legacy withdrawal requires manual hold reconstruction')
            require_coverage(s, reserve)
            # Offline liquidity evidence is independent of the internal journal.
            pending = s.scalars(select(Withdrawal).where(Withdrawal.status.in_(['SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN']))).all()
            if Decimal(provider.custody_balance) - sum((r.amount for r in pending), Decimal('0')) < row.amount:
                raise ValueError('insufficient payout liquidity')
            user,address,amount,order_id=row.user_id,row.address,row.amount,row.id
            state = s.get(WalletSafetyState, 'global')
            epoch = state.epoch if state else 0
            digest = hashlib.sha256(json.dumps({'id':order_id, 'network':'TRC20', 'asset':'USDT-TRC20', 'address':address, 'amount':str(amount), 'finance':row.finance_approver_id, 'admin':row.admin_approver_id, 'epoch':epoch}, sort_keys=True).encode()).hexdigest()
            s.add(WalletPayoutIntent(withdrawal_id=order_id, digest=digest, epoch=epoch, created_at=datetime.now(timezone.utc)))
            row.status = 'SUBMITTING'
            if reserve is not None:
                reserve.pending_payouts += 1
                reserve.version += 1
            audit_write(s, actor_id, row.id, 'wallet.submitting', 'WITHDRAWAL_SUBMIT')
            s.flush()
        # Committed claim prevents concurrent workers submitting the same intent.
        try:
            if self.withdrawals_paused():
                raise ValueError('withdrawals paused after intent')
            txid=provider.submit_withdrawal(client_order_id=order_id,address=address,amount=amount)
        except Exception:
            with self.factory.begin() as s:
                row=s.get(Withdrawal,id, with_for_update=True)
                if row.status == 'SUBMITTING':
                    row.status='UNKNOWN'
                    audit_write(s, actor_id, row.id, 'wallet.withdrawal_unknown', 'CUSTODY_RESULT_UNKNOWN')
            raise
        with self.factory.begin() as s:
            row=s.get(Withdrawal,id, with_for_update=True)
            if row.status == 'SUBMITTING':
                row.provider_txid=txid; row.status="PROVIDER_SUBMITTED"; row.updated_at=datetime.now(timezone.utc); s.flush()
                audit_write(s, actor_id, row.id, 'wallet.provider_submitted', 'WITHDRAWAL_SUBMIT')
            return row
    def pause_on_reconciliation_mismatch(self,reason, *, actor_id='reconciliation-worker'):
        with self.factory.begin() as s:
            lock_budget(s)
            row=s.get(WalletControl,"global")
            if row is None: row=WalletControl(id="global",withdrawals_paused=True,pause_reason=reason); s.add(row)
            else: row.withdrawals_paused=True; row.pause_reason=reason
            state=s.get(WalletSafetyState, 'global', with_for_update=True)
            if state is None:
                s.add(WalletSafetyState(id='global', restricted=True, epoch=1, reason=reason))
            else:
                state.epoch += 1
                state.restricted = True
                state.reason = reason
            audit_write(s, actor_id, 'global', 'wallet.paused', 'RECONCILIATION_MISMATCH')
    def withdrawals_paused(self):
        with self.factory() as s:
            row=s.get(WalletControl,"global")
            return bool(row and row.withdrawals_paused)

@dataclass(frozen=True)
class ReconciliationResult:
    mode: str
    expected: Decimal
    actual: Decimal
    matched: bool
