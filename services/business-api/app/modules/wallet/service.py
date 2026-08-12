from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4
import hmac
from sqlalchemy import func, select
from app.core.errors import AppError
from app.modules.wallet.models import Deposit, WalletControl, WalletLedgerEntry, WalletLedgerTransaction, WalletWebhookEvent, Withdrawal
USDT = Decimal("0.000001")
def usdt(value): return Decimal(value).quantize(USDT, rounding=ROUND_HALF_UP)
class WalletLedger:
    def __init__(self, session_factory): self.factory = session_factory
    def post(self, *, entries, actor_id, reason_code, idempotency_key, scope):
        normalized={k:usdt(v) for k,v in entries.items() if usdt(v)!=0}
        if not normalized or sum(normalized.values(), Decimal("0")) != Decimal("0"): raise ValueError("wallet ledger entries must be balanced")
        now=datetime.now(timezone.utc)
        with self.factory.begin() as session:
            existing=session.scalar(select(WalletLedgerTransaction).where(WalletLedgerTransaction.scope==scope, WalletLedgerTransaction.idempotency_key==idempotency_key))
            if existing: return existing
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
    def credit_for_test(self,user_id,amount): return self.wallet_ledger.post(entries={user_id:usdt(amount),"PLATFORM_CUSTODY":-usdt(amount)},actor_id="test",reason_code="TEST_CREDIT",idempotency_key=f"test-credit:{user_id}:{amount}",scope="wallet.deposit")
    def handle_deposit_webhook(self,payload,signature):
        if not hmac.compare_digest(self.provider.sign(payload),signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID",message="托管回调签名无效",status_code=401)
        if payload.get("asset")!="USDT-TRC20" or payload.get("type")!="DEPOSIT_CONFIRMED": raise ValueError("unsupported custody event")
        event_id=payload["event_id"]; now=datetime.now(timezone.utc)
        with self.factory.begin() as session:
            existing=session.scalar(select(Deposit).where(Deposit.event_id==event_id))
            if existing: return existing.status
            deposit=Deposit(id=str(uuid4()),event_id=event_id,user_id=payload["user_id"],txid=payload["txid"],amount=usdt(payload["amount"]),confirmations=int(payload["confirmations"]),status="CONFIRMED" if int(payload["confirmations"])>=self.confirmation_threshold else "PENDING",created_at=now); session.add(deposit); session.flush()
        if deposit.status=="CONFIRMED":
            self.wallet_ledger.post(entries={deposit.user_id:deposit.amount,"PLATFORM_CUSTODY":-deposit.amount},actor_id="custody-webhook",reason_code="DEPOSIT_CONFIRMED",idempotency_key=f"deposit:{event_id}",scope="wallet.deposit")
            with self.factory.begin() as session:
                session.get(Deposit, deposit.id).status = "CREDITED"
            return "CREDITED"
        return deposit.status
    def request_withdrawal(self, *, user_id, amount, address, client_order_id, reason_code):
        amount=usdt(amount)
        if amount<=0 or not address or not reason_code: raise ValueError("invalid withdrawal request")
        now=datetime.now(timezone.utc)
        with self.factory.begin() as session:
            existing=session.scalar(select(Withdrawal).where(Withdrawal.user_id==user_id,Withdrawal.client_order_id==client_order_id))
            if existing: return existing
            row=Withdrawal(id=str(uuid4()),user_id=user_id,client_order_id=client_order_id,address=address,amount=amount,status="REQUESTED",created_at=now,updated_at=now); session.add(row); session.flush(); return row

    def handle_withdrawal_webhook(self, payload, signature):
        if not hmac.compare_digest(self.provider.sign(payload), signature): raise AppError(code="CUSTODY_SIGNATURE_INVALID", message="托管回调签名无效", status_code=401)
        if payload.get("asset") != "USDT-TRC20" or payload.get("type") != "WITHDRAWAL_STATUS": raise ValueError("unsupported custody event")
        event_id, status = payload["event_id"], payload["status"]
        if status not in {"CHAIN_CONFIRMED", "FAILED"}: raise ValueError("unsupported withdrawal status")
        with self.factory.begin() as session:
            event = session.get(WalletWebhookEvent, event_id)
            row = session.scalar(select(Withdrawal).where(Withdrawal.client_order_id == payload["client_order_id"]).with_for_update())
            if row is None: raise ValueError("withdrawal order not found")
            if event is not None: return row.status
            session.add(WalletWebhookEvent(event_id=event_id, event_type="WITHDRAWAL_STATUS", received_at=datetime.now(timezone.utc)))
            if row.status == "PROVIDER_SUBMITTED": row.status, row.updated_at = status, datetime.now(timezone.utc)
            session.flush()
            return row.status

    def resolve_unknown_withdrawal(self, withdrawal_id: str, *, actor_id: str) -> Withdrawal:
        with self.factory() as session:
            row = session.get(Withdrawal, withdrawal_id)
            if row is None: raise ValueError("withdrawal not found")
            result = self.provider.get_withdrawal(row.client_order_id)
        status = result.get("status")
        if status == "UNKNOWN": raise ValueError("custody result unknown")
        with self.factory.begin() as session:
            row = session.get(Withdrawal, withdrawal_id)
            if row.status == "PROVIDER_SUBMITTED" and status in {"CHAIN_CONFIRMED", "FAILED"}:
                row.status, row.provider_txid, row.updated_at = status, result.get("txid"), datetime.now(timezone.utc)
            session.flush()
            return row

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
        with self.factory() as s:
            row=s.get(Withdrawal,id)
            if not row or row.status!="FINANCE_APPROVED" or row.amount<=self.admin_threshold: raise ValueError("admin approval not required")
        return self._approve(id,approver_id,"admin_approver_id","FINANCE_APPROVED","ADMIN_APPROVED")
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
            if row.status=="FINANCE_APPROVED" and row.amount>self.admin_threshold: raise ValueError("admin approval required")
            if row.status not in ("FINANCE_APPROVED","ADMIN_APPROVED"): raise ValueError("withdrawal is not approved")
            if self.withdrawals_paused(): raise ValueError("withdrawals paused")
            user,address,amount,order=row.user_id,row.address,row.amount,row.client_order_id
        self.wallet_ledger.post(entries={user:-amount,"PLATFORM_CUSTODY":amount},actor_id=actor_id,reason_code="WITHDRAWAL_SUBMIT",idempotency_key=f"withdraw:{order}",scope="wallet.withdrawal")
        txid=self.provider.submit_withdrawal(client_order_id=order,address=address,amount=amount)
        with self.factory.begin() as s:
            row=s.get(Withdrawal,id); row.provider_txid=txid; row.status="PROVIDER_SUBMITTED"; row.updated_at=datetime.now(timezone.utc); s.flush(); return row
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
