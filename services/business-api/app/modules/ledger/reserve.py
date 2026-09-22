"""Opt-in redeemable-CAIBI budget, locked before any financial account locks.

ADR-0076（点钻人民币计价 v2）：点钻账面数量、参考 USDT 估值与实际 USDT
义务三类数量严格区分——任何储备/对账公式不得把点钻数量与 USDT 数量直接
相加。full_backing 门禁按"点钻参考估值（÷汇率）+ USDT 负债"计提要求；
存在点钻负债而无新鲜汇率时拒绝 full_backing 门禁；不假设 1:1。
"""
from datetime import datetime, timezone
from decimal import Decimal, ROUND_UP

from sqlalchemy import DateTime, Numeric, String, func, select
from sqlalchemy.orm import Mapped, mapped_column
from sqlalchemy.exc import SQLAlchemyError

from app.core.database import Base
from app.modules.ledger.account_locks import lock_accounts
from app.modules.ledger.models import LedgerEntry
from app.modules.fx.models import FxRate


class RedeemabilityReserve(Base):
    __tablename__ = "ledger_redeemability_reserve"
    id: Mapped[str] = mapped_column(String(20), primary_key=True)
    eligible_usdt: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    usdt_liability: Mapped[Decimal] = mapped_column(Numeric(30, 6), nullable=False)
    version: Mapped[int] = mapped_column(nullable=False)
    pending_payouts: Mapped[int] = mapped_column(nullable=False, default=0)
    outgoing_restricted: Mapped[bool] = mapped_column(nullable=False, default=False)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    # ADR-0076：三类数量快照（报表与对账随行数据；可空，估值缺失不伪造）。
    caibi_face: Mapped[Decimal | None] = mapped_column(Numeric(30, 2), nullable=True)
    approved_unpaid_usdt: Mapped[Decimal | None] = mapped_column(Numeric(30, 6), nullable=True)
    valuation_rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6), nullable=True)
    caibi_reference_usdt: Mapped[Decimal | None] = mapped_column(Numeric(30, 6), nullable=True)
    valued_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


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


def fresh_usd_cny_rate(session, *, now=None):
    """Read a fresh persisted quote without issuing an upstream request.

    缺报价返回 None；数据库故障明确拒绝，让外层事务回滚，不吞掉故障。
    """
    try:
        row = session.get(FxRate, 'USD/CNY')
    except SQLAlchemyError:
        from app.core.errors import AppError
        raise AppError(code='RESERVE_VALUATION_UNAVAILABLE',
            message='汇率存储暂不可用，无法核验储备', status_code=503) from None
    if row is None or row.rate is None or row.expires_at is None:
        return None
    expires = row.expires_at if row.expires_at.tzinfo else row.expires_at.replace(tzinfo=timezone.utc)
    now = now or datetime.now(timezone.utc)
    if expires <= now:
        return None
    rate = Decimal(row.rate)
    return rate if rate.is_finite() and rate > 0 else None


def caibi_requirement_usdt(caibi_face: Decimal, rate: Decimal | None) -> Decimal:
    """门禁用点钻 USDT 折算要求：÷汇率并向上取整（宁严勿松）；
    无新鲜汇率且有点钻负债时拒绝，不虚构估值。"""
    if rate is not None and (not rate.is_finite() or rate <= 0):
        raise ValueError('invalid reserve valuation rate')
    if caibi_face == 0:
        return Decimal('0.000000')
    if rate is None:
        from app.core.errors import AppError
        raise AppError(code='RESERVE_VALUATION_UNAVAILABLE', message='缺少新鲜汇率，无法核验点钻储备', status_code=503)
    divisor = rate
    return (caibi_face / divisor).quantize(Decimal('0.000001'), rounding=ROUND_UP)


def full_backing_required_usdt(session, reserve, *, caibi_delta=Decimal('0'), usdt_delta=Decimal('0')):
    required = Decimal(reserve.usdt_liability) + usdt_delta
    required += caibi_requirement_usdt(caibi_liability(session) + caibi_delta, fresh_usd_cny_rate(session))
    return required


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
    if policy == 'full_backing':
        required = full_backing_required_usdt(session, reserve, caibi_delta=caibi_delta, usdt_delta=usdt_delta)
        if reserve.eligible_usdt < required:
            raise ValueError('insufficient reserve coverage')


def approved_unpaid_usdt(session) -> Decimal:
    """已批准未支付出款订单的在途 USDT 应付额（informational；其冻结
    已含在 usdt_liability 的 HOLD 科目内，不重复并入义务）。"""
    from app.modules.wallet.models import Withdrawal
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder

    legacy = session.scalar(select(func.coalesce(func.sum(Withdrawal.amount), 0)).where(
        Withdrawal.status.in_(('SUBMITTING', 'PROVIDER_SUBMITTED', 'UNKNOWN'))))
    manual = session.scalar(select(func.coalesce(func.sum(func.coalesce(
        ManualPayoutOrder.final_receive, ManualPayoutOrder.amount)), 0)).where(
        ManualPayoutOrder.status.in_(('REQUESTED', 'CLAIMED', 'UNKNOWN'))))
    return Decimal(legacy) + Decimal(manual)


def usdt_obligation(session) -> Decimal:
    """实际 USDT 义务（含冻结 HOLD = 已批准未支付订单；延迟导入避免环）。"""
    from app.modules.wallet.safety import usdt_liability

    return usdt_liability(session)


def reserve_valuation_snapshot(session, *, now=None) -> dict:
    """ADR-0076 决策6：三类数量一次读齐（估值缺失返回 None，不伪造）。"""
    rate = fresh_usd_cny_rate(session, now=now)
    face = caibi_liability(session).quantize(Decimal('0.01'))
    return {
        "caibi_face": face,
        "valuation_rate": rate,
        "caibi_reference_usdt": None if rate is None else (face / rate).quantize(Decimal('0.000001'), rounding=ROUND_UP),
        "usdt_obligation": usdt_obligation(session).quantize(Decimal('0.000001')),
        "approved_unpaid_usdt": approved_unpaid_usdt(session).quantize(Decimal('0.000001')),
    }


def refresh_valuation(session, reserve, *, now=None):
    """把三类数量写入储备行（对账/覆盖等已持有行锁的路径调用）。"""
    if reserve is None:
        return
    rate = fresh_usd_cny_rate(session, now=now)
    face = caibi_liability(session).quantize(Decimal('0.01'))
    reserve.caibi_face = face
    reserve.valuation_rate = rate
    reserve.caibi_reference_usdt = None if rate is None else (face / rate).quantize(Decimal('0.000001'), rounding=ROUND_UP)
    reserve.approved_unpaid_usdt = approved_unpaid_usdt(session).quantize(Decimal('0.000001'))
    reserve.valued_at = now or datetime.now(timezone.utc)
