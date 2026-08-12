from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import hashlib
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.models import LedgerEntry, LedgerTransaction

CENT = Decimal("0.01")

def money(value: Decimal) -> Decimal:
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)

class LedgerService:
    def __init__(self, session_factory):
        self.session_factory = session_factory

    def balance(self, account_id: str) -> Decimal:
        with self.session_factory() as session:
            value = session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(LedgerEntry.account_id == account_id, LedgerEntry.asset == "CAIBI"))
            return money(Decimal(value))

    def post(self, *, entries: dict[str, Decimal], actor_id: str, reason_code: str, idempotency_key: str, scope: str = "ledger.post", reversal_of_id: str | None = None) -> LedgerTransaction:
        if not idempotency_key or not reason_code or not actor_id:
            raise ValueError("idempotency key, actor and reason code are required")
        normalized = {account: money(amount) for account, amount in entries.items() if money(amount) != 0}
        if not normalized or sum(normalized.values(), Decimal("0.00")) != Decimal("0.00"):
            raise ValueError("ledger entries must be balanced")
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
            existing = session.scalar(select(LedgerTransaction).options(selectinload(LedgerTransaction.entries)).where(LedgerTransaction.scope == scope, LedgerTransaction.idempotency_key == idempotency_key))
            if existing:
                persisted = {entry.account_id: money(entry.amount) for entry in existing.entries}
                if persisted != normalized or existing.actor_id != actor_id or existing.reason_code != reason_code or existing.reversal_of_id != reversal_of_id:
                    raise ValueError("idempotency key reused with different payload")
                return existing
            for account, delta in normalized.items():
                if delta < 0 and not account.startswith("PLATFORM_"):
                    current = session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(LedgerEntry.account_id == account, LedgerEntry.asset == "CAIBI"))
                    if money(Decimal(current)) + delta < 0:
                        raise ValueError("insufficient balance")
            tx = LedgerTransaction(id=str(uuid4()), asset="CAIBI", scope=scope, idempotency_key=idempotency_key, actor_id=actor_id, reason_code=reason_code, reversal_of_id=reversal_of_id, created_at=now)
            session.add(tx)
            session.flush()
            for account, amount in normalized.items():
                session.add(LedgerEntry(id=str(uuid4()), transaction_id=tx.id, account_id=account, asset="CAIBI", amount=amount, created_at=now))
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="ledger_transaction", subject_id=tx.id, action="ledger.post", result="SUCCESS", reason_code=reason_code, trace_id=hashlib.sha256(idempotency_key.encode()).hexdigest()[:32], after_data={"asset": "CAIBI", "entry_count": len(normalized)}, created_at=now))
            OutboxPublisher.enqueue(session, topic="ledger", event_type="ledger.posted", aggregate_type="ledger_transaction", aggregate_id=tx.id, payload={"transaction_id": tx.id, "asset": "CAIBI"}, now=now)
            session.flush()
            _ = tx.entries
            return tx

    def adjust(self, *, user_id: str, amount: Decimal, actor_id: str, reason_code: str, idempotency_key: str) -> LedgerTransaction:
        amount = money(amount)
        if amount == 0:
            raise ValueError("adjustment amount must be non-zero")
        return self.post(entries={user_id: amount, "PLATFORM_CLEARING": -amount}, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="ledger.adjustment")

    def reverse(self, original_id: str, reason_code: str, actor_id: str, idempotency_key: str) -> LedgerTransaction:
        with self.session_factory() as session:
            original = session.scalar(select(LedgerTransaction).options(selectinload(LedgerTransaction.entries)).where(LedgerTransaction.id == original_id))
            if not original:
                raise ValueError("original transaction not found")
            entries = {entry.account_id: -entry.amount for entry in original.entries}
        return self.post(entries=entries, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="ledger.reversal", reversal_of_id=original_id)

@dataclass(frozen=True)
class TransferResult:
    transaction: LedgerTransaction
    fee: Decimal

class PointTransferService:
    def __init__(self, ledger: LedgerService):
        self.ledger = ledger

    def transfer(self, *, sender_id: str, receiver_id: str, amount: Decimal, actor_id: str, reason_code: str, idempotency_key: str) -> TransferResult:
        amount = money(amount)
        if amount <= 0 or sender_id == receiver_id:
            raise ValueError("invalid transfer")
        fee = max(CENT, money(amount * Decimal("0.005")))
        tx = self.ledger.post(entries={sender_id: -(amount + fee), receiver_id: amount, "PLATFORM_FEE": fee}, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="caibi.transfer")
        return TransferResult(tx, fee)

