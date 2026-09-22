"""Public reserve mutations for manual payouts; never infer custody balances."""
from datetime import datetime, timezone
from decimal import Decimal, localcontext

from app.modules.ledger.reserve import full_backing_required_usdt


def require_manual_payout_coverage(session, reserve, *, now, policy='full_backing'):
    if reserve is None:
        raise ValueError('reserve evidence missing')
    observed = reserve.observed_at
    if observed.tzinfo is None:
        observed = observed.replace(tzinfo=timezone.utc)
    if not 0 <= (now - observed).total_seconds() <= 120:
        raise ValueError('reserve evidence stale')
    if reserve.outgoing_restricted or reserve.pending_payouts:
        raise ValueError('reserve outgoing restricted')
    if policy not in {'full_backing', 'manual_liquidity'}:
        raise ValueError('invalid reserve policy')
    if policy == 'full_backing':
        # ADR-0076：点钻按新鲜参考报价估值；有点钻负债但缺报价时拒绝，不跨单位相加。
        with localcontext() as ctx:
            ctx.prec = 50
            required = full_backing_required_usdt(session, reserve)
            if reserve.eligible_usdt < required:
                raise ValueError('insufficient reserve coverage')


def mark_manual_payout_pending(reserve):
    if reserve is None:
        raise ValueError('reserve evidence missing')
    reserve.pending_payouts += 1
    reserve.observed_at = datetime(1970, 1, 1, tzinfo=timezone.utc)
    reserve.version += 1


def finish_manual_payout_pending(reserve):
    if reserve is None or reserve.pending_payouts < 1:
        raise ValueError('manual payout reserve obligation missing')
    reserve.pending_payouts -= 1
    reserve.observed_at = datetime(1970, 1, 1, tzinfo=timezone.utc)
    reserve.version += 1
