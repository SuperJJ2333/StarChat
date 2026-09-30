"""Exact paired reversals preserve the beneficiary and actual operation actor."""
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from app.modules.audit.models import AuditEvent
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.wallet.conversions import reverse_payout_conversion
from app.modules.wallet.models import WalletConversion, WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.service import WalletLedger
from test_manual_payout_rate import core, _caibi_quote, _request  # noqa: F401


def release_hold(core, *, reason_code, actor_id):
    service, factory = core[:2]
    order = _request(core, _caibi_quote(core))
    with factory.begin() as session:
        WalletLedger(factory).post(session=session,
            entries={'HOLD:alice': Decimal('-10.000000'), 'alice': Decimal('10.000000')},
            actor_id=actor_id, reason_code=reason_code, idempotency_key=order['id'],
            scope='wallet.manual_void_release' if reason_code == 'MANUAL_PAYOUT_VOIDED' else 'wallet.manual_release')
    return order


@pytest.mark.parametrize(('reason_code', 'actor_id'), [
    ('MANUAL_PAYOUT_CANCELLED', 'alice'),
    ('MANUAL_PAYOUT_REJECTED', 'owner'),
    ('MANUAL_PAYOUT_VOIDED', 'owner'),
])
def test_exact_payout_conversion_reversal_preserves_actor_reason_and_replay(core, reason_code, actor_id):
    """Reject a missing void reason, a beneficiary-as-admin actor, or duplicate refund."""
    factory = core[1]
    order = release_hold(core, reason_code=reason_code, actor_id=actor_id)
    arguments = dict(user_id='alice', actor_id=actor_id, reason_code=reason_code,
        order_id=order['id'], amount=Decimal('10.000000'))
    with factory.begin() as session:
        reversal_id = reverse_payout_conversion(session, factory, **arguments).id
    with factory.begin() as session:
        assert reverse_payout_conversion(session, factory, **arguments).id == reversal_id
    assert WalletLedger(factory).balance('alice') == Decimal('1000.000000')
    assert WalletLedger(factory).balance('HOLD:alice') == Decimal('0.000000')
    assert LedgerService(factory).balance('alice') == Decimal('500.00')
    with factory() as session:
        original = session.scalar(select(WalletConversion).where(
            WalletConversion.idempotency_key == 'payout:'+order['id']))
        release = session.scalar(select(WalletLedgerTransaction).where(
            WalletLedgerTransaction.scope == 'wallet.conversion_reversal'))
        debit = session.scalar(select(LedgerTransaction).where(LedgerTransaction.scope == 'wallet.conversion'))
        mirrors = list(session.scalars(select(LedgerTransaction).where(
            LedgerTransaction.scope == 'wallet.conversion_reversal')))
        assert len(mirrors) == 1
        mirror = mirrors[0]
        assert release.actor_id == mirror.actor_id == actor_id
        assert release.reason_code == mirror.reason_code == reason_code
        assert release.idempotency_key == mirror.idempotency_key == 'reverse:'+original.id
        assert mirror.reversal_of_id == debit.id
        wallet_entries = {entry.account_id: entry.amount for entry in session.scalars(
            select(WalletLedgerEntry).where(WalletLedgerEntry.transaction_id == release.id))}
        caibi_entries = {entry.account_id: entry.amount for entry in session.scalars(
            select(LedgerEntry).where(LedgerEntry.transaction_id == mirror.id))}
        assert wallet_entries == {'alice': Decimal('-10.000000'), 'PLATFORM_CONVERSION': Decimal('10.000000')}
        assert caibi_entries == {'alice': Decimal('71.20'), 'PLATFORM_CLEARING': Decimal('-71.20')}
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.action == 'wallet.conversion_reversed', AuditEvent.actor_id == actor_id,
            AuditEvent.reason_code == reason_code)) == 1
    for changed in ({'actor_id': 'bob'}, {'reason_code': 'MANUAL_PAYOUT_REJECTED'
            if reason_code != 'MANUAL_PAYOUT_REJECTED' else 'MANUAL_PAYOUT_VOIDED'}):
        with pytest.raises(ValueError), factory.begin() as session:
            reverse_payout_conversion(session, factory, **(arguments | changed))
    assert LedgerService(factory).balance('alice') == Decimal('500.00')


def void_wallet_release(core):
    factory = core[1]
    order = release_hold(core, reason_code='MANUAL_PAYOUT_VOIDED', actor_id='owner')
    with factory.begin() as session:
        original = session.scalar(select(WalletConversion).where(
            WalletConversion.idempotency_key == 'payout:'+order['id']))
        release = WalletLedger(factory).post(session=session,
            entries={'alice': Decimal('-10.000000'), 'PLATFORM_CONVERSION': Decimal('10.000000')},
            actor_id='owner', reason_code='MANUAL_PAYOUT_VOIDED', idempotency_key='reverse:'+original.id,
            scope='wallet.conversion_reversal')
        return original.id, release.id


def test_wallet_release_proof_accepts_void_reason_with_actual_owner(core):
    conversion_id, release_id = void_wallet_release(core)
    with core[1].begin() as session:
        WalletLedger(core[1]).require_conversion_release(session=session, user_id='alice',
            actor_id='owner', reason_code='MANUAL_PAYOUT_VOIDED', conversion_id=conversion_id,
            release_id=release_id, amount=Decimal('71.20'))
        for changed in ({'actor_id': 'alice'}, {'reason_code': 'MANUAL_PAYOUT_CANCELLED'},
                {'user_id': 'bob'}, {'amount': Decimal('71.19')}):
            arguments = dict(user_id='alice', actor_id='owner', reason_code='MANUAL_PAYOUT_VOIDED',
                conversion_id=conversion_id, release_id=release_id, amount=Decimal('71.20'))
            with pytest.raises(ValueError):
                WalletLedger(core[1]).require_conversion_release(session=session, **(arguments | changed))


def test_caibi_replacement_proof_accepts_void_reason_and_exact_original_source(core):
    conversion_id, release_id = void_wallet_release(core)
    ledger = LedgerService(core[1])
    with core[1].begin() as session:
        mirror = ledger.reverse_conversion_debit(session=session, user_id='alice', actor_id='owner',
            reason_code='MANUAL_PAYOUT_VOIDED', conversion_id=conversion_id, wallet_release_id=release_id)
        assert mirror.actor_id == 'owner' and mirror.reason_code == 'MANUAL_PAYOUT_VOIDED'
    assert ledger.balance('alice') == Decimal('500.00')
