from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import hashlib
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.account_locks import lock_accounts
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.reserve import caibi_liability, lock_budget, require_coverage
from app.modules.ledger.restriction_models import LedgerOutgoingRestriction  # noqa: F401

CENT = Decimal("0.01")

def money(value: Decimal) -> Decimal:
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)

class LedgerService:
    reserve_policy = 'full_backing'
    def __init__(self, session_factory):
        self.session_factory = session_factory

    def balance(self, account_id: str) -> Decimal:
        with self.session_factory() as session:
            value = session.scalar(select(func.coalesce(func.sum(LedgerEntry.amount), 0)).where(LedgerEntry.account_id == account_id, LedgerEntry.asset == "CAIBI"))
            return money(Decimal(value))

    def redeemable_liability(self, *, session):
        return caibi_liability(session)

    def restrict_redeemable_outgoing(self, *, session, actor_id, reason_code, scope='legacy_unknown'):
        from app.modules.ledger.restrictions import restrict
        return restrict(session, actor_id=actor_id, reason_code=reason_code, scope=scope)

    def restriction_snapshot(self, *, session):
        from app.modules.ledger.restrictions import snapshot
        return snapshot(session)

    def release_manual_restriction(self, *, session, actor_id, reason_code, expected_epoch):
        from app.modules.ledger.restrictions import release_manual
        return release_manual(session, actor_id=actor_id, reason_code=reason_code, expected_epoch=expected_epoch)

    def post(self, *, entries: dict[str, Decimal], actor_id: str, reason_code: str, idempotency_key: str, scope: str = "ledger.post", reversal_of_id: str | None = None, session=None) -> LedgerTransaction:
        return self._post(entries=entries, actor_id=actor_id, reason_code=reason_code,
            idempotency_key=idempotency_key, scope=scope, reversal_of_id=reversal_of_id, session=session)

    def _post(self, *, entries, actor_id, reason_code, idempotency_key, scope,
              reversal_of_id=None, session=None, conversion_release_id=None):
        if session is None:
            with self.session_factory.begin() as owned_session:
                return self._post(entries=entries, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope=scope, reversal_of_id=reversal_of_id, session=owned_session, conversion_release_id=conversion_release_id)
        if not idempotency_key or not reason_code or not actor_id:
            raise ValueError("idempotency key, actor and reason code are required")
        normalized = {account: money(amount) for account, amount in entries.items() if money(amount) != 0}
        if not normalized or sum(normalized.values(), Decimal("0.00")) != Decimal("0.00"):
            raise ValueError("ledger entries must be balanced")
        now = datetime.now(timezone.utc)
        reserve = lock_budget(session)
        existing = session.scalar(select(LedgerTransaction).options(selectinload(LedgerTransaction.entries)).where(LedgerTransaction.scope == scope, LedgerTransaction.idempotency_key == idempotency_key))
        if existing:
            persisted = {entry.account_id: money(entry.amount) for entry in existing.entries}
            if persisted != normalized or existing.actor_id != actor_id or existing.reason_code != reason_code or existing.reversal_of_id != reversal_of_id:
                raise ValueError("idempotency key reused with different payload")
            return existing
        if reserve is not None and reserve.outgoing_restricted and any(delta < 0 and account not in {'PLATFORM_CLEARING', 'PLATFORM_FEE'} for account, delta in normalized.items()):
            raise ValueError('redeemable outgoing globally restricted')
        liability_delta = sum((delta for account, delta in normalized.items() if account not in {'PLATFORM_CLEARING', 'PLATFORM_FEE'}), Decimal('0'))
        if liability_delta > 0:
            if conversion_release_id is None:
                require_coverage(session, reserve, caibi_delta=liability_delta, policy=self.reserve_policy)
            else:
                self._require_conversion_replacement(session, normalized, actor_id, reason_code,
                    scope, idempotency_key, reversal_of_id, conversion_release_id)
        if reserve is not None:
            reserve.version += 1
        # 并发扣减防护：先对被扣账户取事务级锁再做余额校验，
        # 否则两个并发事务会读到同一余额并双双提交（超扣/双花）。
        lock_accounts(
            session,
            [account for account, delta in normalized.items() if delta < 0],
            asset="CAIBI",
        )
        for account, delta in normalized.items():
            if delta < 0 and account not in {"PLATFORM_CLEARING", "PLATFORM_FEE"}:
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

    def _require_conversion_replacement(self, session, normalized, actor_id, reason_code,
                                        scope, idempotency_key, original_id, release_id):
        """Only a verified, exact paired USDT decrease may replace CAIBI debt.

        No reserve evidence is fabricated and no unrestricted issuance bypass is
        exposed by post(). Every other positive-liability write keeps coverage.
        """
        from app.modules.wallet.service import WalletLedger
        original = session.scalar(select(LedgerTransaction).options(selectinload(LedgerTransaction.entries))
            .where(LedgerTransaction.id == original_id))
        if (original is None or original.scope != 'wallet.conversion'
                or original.reason_code != 'CAIBI_TO_USDT' or original.actor_id != actor_id
                or not original.idempotency_key.startswith('convert:')
                or scope != 'wallet.conversion_reversal' or reason_code != 'MANUAL_PAYOUT_CANCELLED'):
            raise ValueError('invalid conversion reversal source')
        conversion_id = original.idempotency_key.removeprefix('convert:')
        if idempotency_key != 'reverse:'+conversion_id:
            raise ValueError('invalid conversion reversal link')
        source = {entry.account_id: money(entry.amount) for entry in original.entries}
        amount = normalized.get(actor_id, Decimal('0'))
        if (amount <= 0 or normalized != {actor_id: amount, 'PLATFORM_CLEARING': -amount}
                or source != {actor_id: -amount, 'PLATFORM_CLEARING': amount}
                or session.scalar(select(LedgerTransaction.id).where(LedgerTransaction.reversal_of_id == original_id))):
            raise ValueError('conversion debit already reversed or mismatched')
        WalletLedger(self.session_factory).require_conversion_release(session=session,
            user_id=actor_id, conversion_id=conversion_id, release_id=release_id, amount=amount)

    def reverse_conversion_debit(self, *, session, user_id, conversion_id, wallet_release_id):
        """Public exact linked reversal, inside the caller's global-budget lock."""
        lock_budget(session)
        original = session.scalar(select(LedgerTransaction).options(selectinload(LedgerTransaction.entries)).where(
            LedgerTransaction.scope == 'wallet.conversion', LedgerTransaction.idempotency_key == 'convert:'+conversion_id))
        if original is None:
            raise ValueError('conversion debit not found')
        return self._post(entries={entry.account_id: -entry.amount for entry in original.entries},
            actor_id=user_id, reason_code='MANUAL_PAYOUT_CANCELLED', idempotency_key='reverse:'+conversion_id,
            scope='wallet.conversion_reversal', reversal_of_id=original.id, session=session,
            conversion_release_id=wallet_release_id)

    def adjust(self, *, user_id: str, amount: Decimal, actor_id: str, reason_code: str, idempotency_key: str, session=None) -> LedgerTransaction:
        amount = money(amount)
        if amount == 0:
            raise ValueError("adjustment amount must be non-zero")
        return self.post(entries={user_id: amount, "PLATFORM_CLEARING": -amount}, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="ledger.adjustment", session=session)

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

    def transfer(self, *, sender_id: str, receiver_id: str, amount: Decimal, actor_id: str, reason_code: str, idempotency_key: str, session=None) -> TransferResult:
        amount = money(amount)
        if amount <= 0 or sender_id == receiver_id:
            raise ValueError("invalid transfer")
        fee = max(CENT, money(amount * Decimal("0.005")))
        tx = self.ledger.post(entries={sender_id: -(amount + fee), receiver_id: amount, "PLATFORM_FEE": fee}, actor_id=actor_id, reason_code=reason_code, idempotency_key=idempotency_key, scope="caibi.transfer", session=session)
        return TransferResult(tx, fee)


