"""Public in-transaction conversion and linked cancellation application API."""
from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import select

from app.modules.ledger.reserve import lock_budget, require_coverage
from app.modules.ledger.service import LedgerService
from app.modules.wallet.models import WalletConversion
from app.modules.wallet.safety import audit_write, precise_amount


def convert_in_session(session, factory, *, user_id, direction, amount,
                       requested_amount, idempotency_key, reserve_policy, now=None, actor_id=None):
    """Caller owns authorization and transaction; no nested commit or provider I/O."""
    from app.modules.wallet.service import WalletLedger
    if direction not in {'CAIBI_TO_USDT', 'USDT_TO_CAIBI'}:
        raise ValueError('invalid conversion direction')
    amount = precise_amount(amount, Decimal('0.01'))
    requested_amount = precise_amount(requested_amount,
        Decimal('0.01') if direction == 'CAIBI_TO_USDT' else Decimal('0.000001'))
    if amount > requested_amount or not idempotency_key or len(idempotency_key) > 128:
        raise ValueError('invalid conversion intent')
    reserve = lock_budget(session)
    existing = session.scalar(select(WalletConversion).where(
        WalletConversion.user_id == user_id, WalletConversion.idempotency_key == idempotency_key))
    if existing:
        if (existing.direction != direction or existing.requested_amount != requested_amount
                or existing.source_amount != amount or existing.target_amount != amount):
            raise ValueError('conversion idempotency payload conflict')
        return existing
    require_coverage(session, reserve, policy=reserve_policy)
    row = WalletConversion(id=str(uuid4()), user_id=user_id, idempotency_key=idempotency_key,
        direction=direction, requested_amount=requested_amount, source_amount=amount, target_amount=amount,
        status='COMPLETED', created_at=now or datetime.now(timezone.utc))
    ledger, wallet = LedgerService(factory), WalletLedger(factory)
    ledger.reserve_policy = wallet.reserve_policy = reserve_policy
    common = dict(actor_id=actor_id or user_id, reason_code=direction, idempotency_key=f'convert:{row.id}',
        scope='wallet.conversion', session=session)
    if direction == 'CAIBI_TO_USDT':
        ledger.post(entries={user_id: -amount, 'PLATFORM_CLEARING': amount}, **common)
        wallet.post(entries={user_id: amount, 'PLATFORM_CONVERSION': -amount}, **common)
    else:
        wallet.post(entries={user_id: -amount, 'PLATFORM_CONVERSION': amount}, **common)
        ledger.post(entries={user_id: amount, 'PLATFORM_CLEARING': -amount}, **common)
    session.add(row)
    audit_write(session, actor_id or user_id, row.id, 'wallet.converted', direction)
    session.flush()
    return row


def reverse_payout_conversion(session, factory, *, user_id, order_id, amount):
    """Reverse exactly the source conversion after its hold was released.

    ADR-0077：按原转换的镜像冲正——退回原 source 点钻、收回原 target
    USDT（率结报价下 source≠target；旧 1:1 订单两者相等仍走同一逻辑）。
    The original conversion stays immutable. The reversal intent key links the
    wallet-side debit to it; the CAIBI entry also uses reversal_of_id.
    """
    from app.modules.wallet.service import WalletLedger
    lock_budget(session)
    original = session.scalar(select(WalletConversion).where(
        WalletConversion.user_id == user_id, WalletConversion.idempotency_key == 'payout:'+order_id))
    if (original is None or original.direction != 'CAIBI_TO_USDT' or original.status != 'COMPLETED'
            or original.source_amount <= 0 or original.target_amount <= 0
            or (amount is not None and Decimal(amount) != original.target_amount)):
        raise ValueError('payout source conversion mismatch')
    source_amount, target_amount = original.source_amount, original.target_amount
    reversal_key = 'reverse:'+original.id
    existing = session.scalar(select(WalletConversion).where(
        WalletConversion.user_id == user_id, WalletConversion.idempotency_key == reversal_key))
    if existing:
        if existing.direction != 'USDT_TO_CAIBI' or existing.source_amount != target_amount or existing.target_amount != source_amount:
            raise ValueError('payout reversal mismatch')
        return existing
    release = WalletLedger(factory).post(entries={user_id: -target_amount, 'PLATFORM_CONVERSION': target_amount},
        actor_id=user_id, reason_code='MANUAL_PAYOUT_CANCELLED', idempotency_key=reversal_key,
        scope='wallet.conversion_reversal', session=session)
    LedgerService(factory).reverse_conversion_debit(session=session, user_id=user_id,
        conversion_id=original.id, wallet_release_id=release.id)
    reversal = WalletConversion(id=str(uuid4()), user_id=user_id, idempotency_key=reversal_key,
        direction='USDT_TO_CAIBI', requested_amount=target_amount, source_amount=target_amount,
        target_amount=source_amount, status='COMPLETED', created_at=datetime.now(timezone.utc))
    session.add(reversal)
    audit_write(session, user_id, original.id, 'wallet.conversion_reversed', 'MANUAL_PAYOUT_CANCELLED')
    session.flush()
    return reversal


def convert_for_payout(session, factory, *, user_id, caibi_amount, usdt_amount,
                       conversion_rate, fx_snapshot_id=None, idempotency_key, reserve_policy, now=None, actor_id=None):
    """ADR-0077：提现内部兑换（点钻来源 → USDT 应付），按结算汇率折算。

    两账本各自平衡：CAIBI {user:-X, PLATFORM_CLEARING:+X}；
    USDT {user:+Y, PLATFORM_CONVERSION:-Y}，Y = X/率（调用方折算）。
    这是提现状态机的内部环节（ADR-0076 决策3），不受用户侧兑换关闭影响。
    """
    from app.modules.wallet.service import WalletLedger
    from decimal import Decimal as _D
    caibi_amount = precise_amount(caibi_amount, _D('0.01'))
    usdt_amount = precise_amount(usdt_amount, _D('0.000001'))
    if caibi_amount <= 0 or usdt_amount <= 0 or conversion_rate <= 0 or not idempotency_key or len(idempotency_key) > 128:
        raise ValueError('invalid payout conversion intent')
    reserve = lock_budget(session)
    existing = session.scalar(select(WalletConversion).where(
        WalletConversion.user_id == user_id, WalletConversion.idempotency_key == idempotency_key))
    if existing:
        if (existing.direction != 'CAIBI_TO_USDT' or existing.source_amount != caibi_amount
                or existing.target_amount != usdt_amount):
            raise ValueError('conversion idempotency payload conflict')
        return existing
    require_coverage(session, reserve, policy=reserve_policy)
    row = WalletConversion(id=str(uuid4()), user_id=user_id, idempotency_key=idempotency_key,
        direction='CAIBI_TO_USDT', requested_amount=caibi_amount, source_amount=caibi_amount,
        target_amount=usdt_amount, status='COMPLETED', created_at=now or datetime.now(timezone.utc))
    ledger, wallet = LedgerService(factory), WalletLedger(factory)
    ledger.reserve_policy = wallet.reserve_policy = reserve_policy
    common = dict(actor_id=actor_id or user_id, reason_code='CAIBI_TO_USDT',
        idempotency_key=f'convert:{row.id}', scope='wallet.conversion', session=session)
    ledger.post(entries={user_id: -caibi_amount, 'PLATFORM_CLEARING': caibi_amount}, **common)
    wallet.post(entries={user_id: usdt_amount, 'PLATFORM_CONVERSION': -usdt_amount}, **common)
    session.add(row)
    audit_write(session, actor_id or user_id, row.id, 'wallet.converted',
        f'PAYOUT_CAIBI_TO_USDT@rate={conversion_rate}' + (f':snap={fx_snapshot_id}' if fx_snapshot_id else ''))
    session.flush()
    return row
