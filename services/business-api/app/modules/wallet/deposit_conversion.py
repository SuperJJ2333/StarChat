"""Receipt-bound USDT-to-CAIBI conversion inside an existing credit transaction."""
from decimal import Decimal, ROUND_DOWN

from datetime import datetime, timezone
from sqlalchemy import select

from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.reserve import lock_budget
from app.modules.identity.wallet_access import require_wallet_actor
from app.modules.wallet.conversions import convert_in_session
from app.modules.wallet.models import WalletControl, WalletConversion, WalletLedgerEntry, WalletLedgerTransaction, WalletSafetyState
from app.modules.wallet.receipt_models import DepositReceipt
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.ledger.service import money
from app.modules.wallet.safety import precise_amount


KEY_PREFIX = 'deposit-receipt:'


def _exact_entries(session, transaction_id, model, asset):
    rows = list(session.scalars(select(model).where(model.transaction_id == transaction_id)))
    return sorted((entry.account_id, money(entry.amount) if asset == 'CAIBI'
                   else Decimal(entry.amount).quantize(Decimal('0.000001')), entry.asset) for entry in rows)


def convert_credited_receipt(session, factory, *, receipt_id, actor_id, enabled, reserve_policy):
    """Convert only the exact, already-recorded credit for one immutable receipt."""
    if enabled is not True or not actor_id:
        raise ValueError('deposit auto conversion disabled')
    # Match the repository-wide financial lock order: budget → control → user.
    lock_budget(session)
    control = session.get(WalletControl, 'global', with_for_update=True)
    if control is None or control.withdrawals_paused:
        raise ValueError('wallet paused')
    row = session.get(DepositReceipt, receipt_id, with_for_update=True)
    if (row is None or row.status != 'CREDITED' or row.pending_obligation or not row.user_id
            or not row.ledger_transaction_id or row.amount is None):
        raise ValueError('credited receipt required')
    state = session.get(WalletSafetyState, row.user_id, with_for_update=True)
    if state is not None and state.restricted:
        raise ValueError('wallet account restricted')
    global_state = session.get(WalletSafetyState, 'global', with_for_update=True)
    if global_state is not None and global_state.restricted:
        raise ValueError('wallet globally restricted')
    require_wallet_actor(session, user_id=row.user_id, clock=lambda: datetime.now(timezone.utc))
    amount = precise_amount(row.amount, Decimal('0.000001'))
    credit = session.get(WalletLedgerTransaction, row.ledger_transaction_id)
    entry_rows = list(session.scalars(select(WalletLedgerEntry).where(WalletLedgerEntry.transaction_id == row.ledger_transaction_id)))
    entries = [(entry.account_id, Decimal(entry.amount).quantize(Decimal('0.000001')), entry.asset) for entry in entry_rows]
    expected = sorted([(row.user_id, amount, 'USDT-TRC20'), ('PLATFORM_CUSTODY', -amount, 'USDT-TRC20')])
    if (credit is None or credit.asset != 'USDT-TRC20' or credit.scope != 'wallet.deposit.receipt'
            or credit.idempotency_key != 'receipt:' + row.id
            or sorted(entries) != expected):
        raise ValueError('receipt ledger evidence mismatch')
    source = amount.quantize(Decimal('0.01'), rounding=ROUND_DOWN)
    if source <= 0:
        raise ValueError('conversion output below 0.01')
    prior = session.scalar(select(WalletConversion).where(WalletConversion.user_id == row.user_id,
        WalletConversion.idempotency_key == KEY_PREFIX + row.id))
    conversion = convert_in_session(session, factory, user_id=row.user_id,
        direction='USDT_TO_CAIBI', amount=source, requested_amount=amount,
        idempotency_key=KEY_PREFIX + row.id, reserve_policy=reserve_policy, actor_id=actor_id)
    wallet = session.scalar(select(WalletLedgerTransaction).where(
        WalletLedgerTransaction.scope == 'wallet.conversion',
        WalletLedgerTransaction.idempotency_key == 'convert:' + conversion.id))
    ledger = session.scalar(select(LedgerTransaction).where(
        LedgerTransaction.scope == 'wallet.conversion',
        LedgerTransaction.idempotency_key == 'convert:' + conversion.id))
    expected_wallet = sorted([(row.user_id, -source, 'USDT-TRC20'), ('PLATFORM_CONVERSION', source, 'USDT-TRC20')])
    expected_ledger = sorted([(row.user_id, source, 'CAIBI'), ('PLATFORM_CLEARING', -source, 'CAIBI')])
    if (conversion.status != 'COMPLETED' or wallet is None or ledger is None
            or wallet.asset != 'USDT-TRC20' or ledger.asset != 'CAIBI'
            or wallet.reason_code != 'USDT_TO_CAIBI' or ledger.reason_code != 'USDT_TO_CAIBI'
            or _exact_entries(session, wallet.id, WalletLedgerEntry, 'USDT-TRC20') != expected_wallet
            or _exact_entries(session, ledger.id, LedgerEntry, 'CAIBI') != expected_ledger):
        raise ValueError('conversion ledger evidence missing')
    result = {'receipt_id': row.id, 'original_ledger_transaction_id': credit.id,
        'conversion_id': conversion.id, 'wallet_ledger_transaction_id': wallet.id,
        'caibi_ledger_transaction_id': ledger.id, 'source_amount': format(source, '.6f'),
        'target_amount': format(source, '.2f'), 'remainder': format(amount - source, '.6f')}
    if prior is None:
        AuditWriter(factory).record_in_session(session, actor_id=actor_id, subject_type='wallet_receipt',
            subject_id=row.id, action='wallet.deposit_auto_converted', result='SUCCESS',
            reason_code='DEPOSIT_AUTO_CONVERSION', trace_id=conversion.id, after=result)
        OutboxPublisher.enqueue(session, topic='wallet', event_type='wallet.deposit_auto_converted',
            aggregate_type='wallet_receipt', aggregate_id=row.id, payload=result, now=datetime.now(timezone.utc))
    return result
