"""Opt-in redeemable-CAIBI budget, locked before any financial account locks."""
from datetime import datetime, timezone
from decimal import Decimal

from sqlalchemy import DateTime, Numeric, String, func, select
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base
from app.modules.ledger.account_locks import lock_accounts
from app.modules.ledger.models import LedgerEntry


class RedeemabilityReserve(Base):
    __tablename__ = "ledger_redeemability_reserve"
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    eligible_usdt: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    usdt_liability: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    version: Mapped[int] = mapped_column(nullable=False)
    pending_payouts: Mapped[int] = mapped_column(nullable=False, default=0)
    outgoing_restricted: Mapped[bool] = mapped_column(nullable=False, default=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


def lock_budget(session):
    lock_accounts(session, ['GLOBAL_REDEEMABILITY'], asset='GLOBAL')
    return session.get(RedeemabilityReserve, 'global', with_for_update=True)


def caibi_liability(session):
    # Include user holds, transfer and red-packet escrow. Issuance counterpart
    # negatives never reduce user liabilities; known platform accounts excluded.
    totals = session.execute(select(LedgerEntry.account_id, func.sum(LedgerEntry.amount)).where(
        LedgerEntry.asset == 'CAIBI', LedgerEntry.account_id.notin_(['PLATFORM_CLEARING', 'PLATFORM_FEE'])
    ).group_by(LedgerEntry.account_id)).all()
    return sum((max(Decimal(amount), Decimal('0')) for _, amount in totals), Decimal('0.00'))


def require_coverage(session, reserve, *, caibi_delta=Decimal('0'), usdt_delta=Decimal('0'), policy='full_backing'):
    if policy not in {'full_backing', 'manual_liquidity'}:
        raise ValueError('invalid reserve policy')
    if reserve is None:
        if policy == 'manual_liquidity':
            raise ValueError('reserve evidence missing')
        return
    if reserve.pending_payouts and (caibi_delta > 0 or usdt_delta > 0):
        raise ValueError('reserve issuance blocked during unresolved payouts')
    observed = reserve.observed_at.replace(tzinfo=timezone.utc) if reserve.observed_at.tzinfo is None else reserve.observed_at
    if (datetime.now(timezone.utc) - observed).total_seconds() > 120:
        raise ValueError('reserve evidence stale')
    required = caibi_liability(session) + caibi_delta + reserve.usdt_liability + usdt_delta
    if policy == 'full_backing' and reserve.eligible_usdt < required:
        raise ValueError('insufficient reserve coverage')
