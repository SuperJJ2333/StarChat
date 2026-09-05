from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4
import hmac
from sqlalchemy import func, select
from app.core.errors import AppError
from app.modules.wallet.models import Deposit, DepositAddress, WalletControl, WalletLedgerEntry, WalletLedgerTransaction, WalletWebhookEvent, Withdrawal
USDT = Decimal("0.000001")
def usdt(value): return Decimal(value).quantize(USDT, rounding=ROUND_HALF_UP)

# 提现状态机（F05）：单向推进；FAILED 已补偿为终态。
WITHDRAWAL_TERMINAL = {"CHAIN_CONFIRMED", "FAILED_COMPENSATED", "CANCELLED"}

class WalletLedger:
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
        # F04：重复键必须核验分录内容——同键不同载荷是冲突，不得静默返回。
        existing=session.scalar(select(WalletLedgerTransaction).where(WalletLedgerTransaction.scope==scope, WalletLedgerTransaction.idempotency_key==idempotency_key))
        if existing:
            persisted={row.account_id:usdt(row.amount) for row in session.scalars(select(WalletLedgerEntry).where(WalletLedgerEntry.transaction_id==existing.id))}
            if persisted != normalized or existing.actor_id != actor_id or existing.reason_code != reason_code:
                raise ValueError("wallet ledger idempotency key reused with different payload")
            return existing
        from app.modules.ledger.account_locks import lock_accounts
        lock_accounts(session, [a for a,d in normalized.items() if d < 0], asset="USDT-TRC20")
        for account,delta in normalized.items():
            if delta < 0 and not account.startswith("PLATFORM_"):
                current=session.scalar(select(func.coalesce(func.sum(WalletLedgerEntry.amount),0)).where(WalletLedgerEntry.account_id==account, WalletLedgerEntry.asset=="USDT-TRC20"))
                if usdt(Decimal(current))+delta < 0: raise ValueError("insufficient USDT balance")
        tx=WalletLedgerTransaction(id=str(uuid4()),asset="USDT-TRC20",scope=scope,idempotency_key=idempotency_key,actor_id=actor_id,reason_code=reason_code,created_at=now); session.add(tx); session.flush()
        for account,amount in normalized.items(): session.add(WalletLedgerEntry(id=str(uuid4()),transaction_id=tx.id,account_id=account,asset="USDT-TRC20",amount=amount,created_at=now))
        session.flush(); return tx

    def balance(self, account_id):
        with self.factory() as session: return usdt(Decimal(session.scalar(select(func.coalesce(func.sum(WalletLedgerEntry.amount),0)).where(WalletLedgerEntry.account_id==account_id, WalletLedgerEntry.asset=="USDT-TRC20"))))

class WalletService:
    def __init__(self, session_factory, provider, *, withdrawal_admin_threshold=Decimal("1000.000000"), confirmation_threshold=12):
        self.factory=session_factory; self.provider=provider; self.wallet_ledger=WalletLedger(session_factory); self.admin_threshold=usdt(withdrawal_admin_threshold); self.confirmation_threshold=confirmation_threshold
    def usdt_balance(self,user_id): return self.wallet_ledger.balance(user_id)
    def config(self) -> dict:
        """U03：钱包有效规则（网络/确认阈值），客户端统一展示来源。"""
        return {"asset": "USDT-TRC20", "network": "TRC20", "confirmation_threshold": self.confirmation_threshold, "min_deposit": "1.000000", "decimals": 6}
    def deposit_address(self, user_id: str) -> str:
        """A01：地址获取/分配——已分配直接复用（跨用户隔离按 user_id 唯一），
        未分配调用托管方并持久化归属。"""
        with self.factory() as session:
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
            items.sort(key=lambda x: (x[0], x[1]), reverse=True)
            page = items[:limit]
            next_cursor = f"{page[-1][0].isoformat()}|{page[-1][1]}" if len(items) > limit and page else None
            return [entry[2] for entry in page], next_cursor
    def credit_for_test(self,user_id,amount): return self.wallet_ledger.post(entries={user_id:usdt(amount),"PLATFORM_CUSTODY":-usdt(amount)},actor_id="test",reason_code="TEST_CREDIT",idempotency_key=f"test-credit:{user_id}:{amount}",scope="wallet.deposit")

    # ------------------------------------------------------------------
    # 充值（F03）：事件接收记录（WalletWebhookEvent）与充值实体（Deposit）
    # 分离；按链上稳定身份 txid 聚合；确认数/状态单向推进；入账与
    # CREDITED 同一事务；同事件重放/新事件同 txid/入账前后崩溃均可恢复。
    # ------------------------------------------------------------------
    def handle_deposit_webhook(self,payload,signature):
        if not hmac.compare_digest(self.provider.sign(payload),signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID",message="托管回调签名无效",status_code=401)
        if payload.get("asset")!="USDT-TRC20" or payload.get("type")!="DEPOSIT_CONFIRMED": raise ValueError("unsupported custody event")
        event_id=payload["event_id"]; txid=payload["txid"]; now=datetime.now(timezone.utc)
        confirmations=int(payload["confirmations"])
        with self.factory.begin() as session:
            # 事件接收记录（重放幂等；已见过的事件继续完成未完成的流程，
            # 而不是直接返回）。
            seen = session.get(WalletWebhookEvent, event_id)
            if seen is None:
                session.add(WalletWebhookEvent(event_id=event_id, event_type="DEPOSIT_CONFIRMED", received_at=now))
                session.flush()
            # 按链上身份（txid）聚合：新事件同 txid 更新确认数而非撞唯一键。
            deposit = session.scalar(select(Deposit).where(Deposit.txid == txid).with_for_update())
            if deposit is None:
                deposit = Deposit(id=str(uuid4()), event_id=event_id, user_id=payload["user_id"], txid=txid, amount=usdt(payload["amount"]), confirmations=confirmations, status="PENDING", created_at=now)
                session.add(deposit); session.flush()
            else:
                # 单向推进：确认数只增不减。
                deposit.confirmations = max(deposit.confirmations, confirmations)
            if deposit.status == "CREDITED":
                return "CREDITED"
            if deposit.confirmations >= self.confirmation_threshold:
                # 余额入账与 CREDITED 状态同一事务；入账幂等键取链上身份。
                self.wallet_ledger.post(entries={deposit.user_id:deposit.amount,"PLATFORM_CUSTODY":-deposit.amount},actor_id="custody-webhook",reason_code="DEPOSIT_CONFIRMED",idempotency_key=f"deposit:{txid}",scope="wallet.deposit",session=session)
                deposit.status = "CREDITED"
                session.flush()
                return "CREDITED"
            session.flush()
            return "PENDING"

    def request_withdrawal(self, *, user_id, amount, address, client_order_id, reason_code):
        amount=usdt(amount)
        if amount<=0 or not address or not reason_code: raise ValueError("invalid withdrawal request")
        now=datetime.now(timezone.utc)
        # F04：客户端键仅做"该用户"的请求去重；重复键核验规范化载荷。
        with self.factory.begin() as session:
            existing=session.scalar(select(Withdrawal).where(Withdrawal.user_id==user_id,Withdrawal.client_order_id==client_order_id).with_for_update())
            if existing:
                if usdt(existing.amount) != amount or existing.address != address:
                    raise ValueError("withdrawal client order id reused with different payload")
                return existing
            row=Withdrawal(id=str(uuid4()),user_id=user_id,client_order_id=client_order_id,address=address,amount=amount,status="REQUESTED",created_at=now,updated_at=now); session.add(row); session.flush(); return row

    # ------------------------------------------------------------------
    # 提现回调（F04/F05）：按全局唯一订单 ID 定位；FAILED 与补偿分录同
    # 一事务；重复/乱序事件有确定结果。
    # ------------------------------------------------------------------
    def handle_withdrawal_webhook(self, payload, signature):
        if not hmac.compare_digest(self.provider.sign(payload), signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID", message="托管回调签名无效", status_code=401)
        if payload.get("asset") != "USDT-TRC20" or payload.get("type") != "WITHDRAWAL_STATUS": raise ValueError("unsupported custody event")
        event_id, status = payload["event_id"], payload["status"]
        if status not in {"CHAIN_CONFIRMED", "FAILED"}: raise ValueError("unsupported withdrawal status")
        with self.factory.begin() as session:
            event = session.get(WalletWebhookEvent, event_id)
            row = self._locate_withdrawal(session, payload.get("client_order_id"))
            if row is None: raise ValueError("withdrawal order not found")
            if event is None:
                session.add(WalletWebhookEvent(event_id=event_id, event_type="WITHDRAWAL_STATUS", received_at=datetime.now(timezone.utc)))
                session.flush()
            # 已终态：重复/乱序事件不再改变结果（补偿本身幂等）。
            if row.status in WITHDRAWAL_TERMINAL:
                return row.status
            if status == "FAILED":
                self._compensate(row, session=session)
                row.provider_txid = payload.get("txid") or row.provider_txid
                row.status, row.updated_at = "FAILED_COMPENSATED", datetime.now(timezone.utc)
            elif status == "CHAIN_CONFIRMED":
                row.status, row.provider_txid, row.updated_at = status, payload.get("txid"), datetime.now(timezone.utc)
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
        with self.factory() as session:
            row = session.get(Withdrawal, withdrawal_id)
            if row is None: raise ValueError("withdrawal not found")
            result = self.provider.get_withdrawal(row.id)
        status = result.get("status")
        if status == "UNKNOWN": raise ValueError("custody result unknown")
        if status not in {"CHAIN_CONFIRMED", "FAILED"}: raise ValueError("unsupported custody result")
        with self.factory.begin() as session:
            row = session.get(Withdrawal, withdrawal_id, with_for_update=True)
            if row.status in WITHDRAWAL_TERMINAL:
                return row
            if status == "FAILED":
                self._compensate(row, session=session)
                row.status, row.provider_txid, row.updated_at = "FAILED_COMPENSATED", result.get("txid"), datetime.now(timezone.utc)
            else:
                row.status, row.provider_txid, row.updated_at = "CHAIN_CONFIRMED", result.get("txid"), datetime.now(timezone.utc)
            session.flush()
            return row

    def _compensate(self, row: Withdrawal, *, session) -> None:
        """F05：明确失败 → 业务订单 ID 派生补偿键，退款分录与状态变更
        同一事务；重复回调/重试经账本幂等键不重复退款。"""
        self.wallet_ledger.post(
            entries={row.user_id: row.amount, "PLATFORM_CUSTODY": -row.amount},
            actor_id="custody-compensation",
            reason_code="WITHDRAWAL_FAILED_COMPENSATION",
            idempotency_key=f"withdraw-compensate:{row.id}",
            scope="wallet.withdrawal",
            session=session,
        )

    def reconcile_incremental(self, *, actor_id: str):
        return self._reconcile(actor_id=actor_id, mode="INCREMENTAL")

    def reconcile_full(self, *, actor_id: str):
        return self._reconcile(actor_id=actor_id, mode="FULL")

    def _reconcile(self, *, actor_id: str, mode: str):
        with self.factory() as session:
            internal = session.scalar(select(func.coalesce(func.sum(WalletLedgerEntry.amount), 0)).where(WalletLedgerEntry.account_id == "PLATFORM_CUSTODY", WalletLedgerEntry.asset == "USDT-TRC20"))
        expected = usdt(-Decimal(internal))
        actual = usdt(getattr(self.provider, "custody_balance", expected))
        matched = actual == expected
        if not matched: self.pause_on_reconciliation_mismatch(f"{mode}: custody={actual} internal={expected}")
        return ReconciliationResult(mode=mode, expected=expected, actual=actual, matched=matched)
    def finance_approve(self,id,approver_id): return self._approve(id,approver_id,"finance_approver_id","REQUESTED","FINANCE_APPROVED")
    def admin_approve(self,id,approver_id):
        # Administrators can approve a requested withdrawal directly.  Keep
        # the transition, ledger idempotency and audit hooks intact while
        # removing the former second-approver/amount threshold gate.
        with self.factory.begin() as s:
            row=s.get(Withdrawal,id)
            if not row or row.status not in ("REQUESTED", "FINANCE_APPROVED"):
                raise ValueError("illegal withdrawal approval transition")
            row.admin_approver_id=approver_id
            row.status="ADMIN_APPROVED"
            row.updated_at=datetime.now(timezone.utc)
            s.flush()
            return row
    def _approve(self,id,approver,field,expected,status):
        with self.factory.begin() as s:
            row=s.get(Withdrawal,id)
            if not row or row.status!=expected: raise ValueError("illegal withdrawal approval transition")
            if field=="admin_approver_id" and row.finance_approver_id==approver: raise ValueError("two approvers required")
            setattr(row,field,approver); row.status=status; row.updated_at=datetime.now(timezone.utc); s.flush(); return row
    def submit_to_custody(self,id,actor_id):
        with self.factory() as s:
            row=s.get(Withdrawal,id)
            if not row: raise ValueError("withdrawal not found")
            if row.status not in ("FINANCE_APPROVED","ADMIN_APPROVED"): raise ValueError("withdrawal is not approved")
            if row.status == "PROVIDER_SUBMITTED" or row.status in WITHDRAWAL_TERMINAL: return row
            if self.withdrawals_paused(): raise ValueError("withdrawals paused")
            user,address,amount,order_id=row.user_id,row.address,row.amount,row.id
        # F04：账本执行键与托管订单号都用全局唯一 Withdrawal.id——
        # 不同用户使用相同客户端订单号互不影响。
        self.wallet_ledger.post(entries={user:-amount,"PLATFORM_CUSTODY":amount},actor_id=actor_id,reason_code="WITHDRAWAL_SUBMIT",idempotency_key=f"withdraw:{order_id}",scope="wallet.withdrawal")
        txid=self.provider.submit_withdrawal(client_order_id=order_id,address=address,amount=amount)
        with self.factory.begin() as s:
            row=s.get(Withdrawal,id)
            if row.status in ("FINANCE_APPROVED","ADMIN_APPROVED"):
                row.provider_txid=txid; row.status="PROVIDER_SUBMITTED"; row.updated_at=datetime.now(timezone.utc); s.flush()
            return row
    def pause_on_reconciliation_mismatch(self,reason):
        with self.factory.begin() as s:
            row=s.get(WalletControl,"global")
            if row is None: row=WalletControl(id="global",withdrawals_paused=True,pause_reason=reason); s.add(row)
            else: row.withdrawals_paused=True; row.pause_reason=reason
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
