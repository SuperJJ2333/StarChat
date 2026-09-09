"""Public reserve integration for wallet-owned pending obligations.

The caller holds the standard budget lock and owns the transaction. This module
alone mutates the ledger reserve; chain receipts never infer eligible custody.
"""
from datetime import datetime, timezone
from decimal import Decimal, localcontext
from app.modules.ledger.reserve import lock_budget, require_coverage


def synchronize_wallet_liability(session, *, total):
    total = Decimal(total)
    if not total.is_finite() or total < 0:
        raise ValueError('invalid wallet liability')
    reserve = lock_budget(session)
    if total >= Decimal('1000000000000000000000000'):
        # Numeric(30,6) cannot store this exact total. Preserve receipt facts and
        # the last representable reserve total, but deny issuance until reviewed.
        invalidate_wallet_reserve(session)
        return reserve
    if reserve is not None and reserve.usdt_liability != total:
        reserve.usdt_liability = total
        reserve.version += 1
    return reserve


def transfer_pending_to_credit(session, *, amount, now, policy='full_backing'):
    reserve = lock_budget(session)
    if reserve is None:
        raise ValueError('reserve evidence missing')
    observed = reserve.observed_at
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    if not 0 <= (now - observed).total_seconds() <= 120:
        raise ValueError('reserve evidence stale')
    with localcontext() as context:
        context.prec = max(40, context.prec)
        require_coverage(session, reserve, policy=policy)
        if reserve.usdt_liability < amount:
            raise ValueError('pending obligation not reconciled')
        reserve.usdt_liability -= amount
    reserve.version += 1


def invalidate_wallet_reserve(session):
    reserve = lock_budget(session)
    if reserve is not None:
        epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
        observed = reserve.observed_at
        if observed.tzinfo is None:
            observed = observed.replace(tzinfo=timezone.utc)
        if observed == epoch:
            return
        reserve.observed_at = epoch
        reserve.version += 1
