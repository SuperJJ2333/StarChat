"""Isolated PostgreSQL payout concurrency; reuses the PIN rehearsal schema fixture."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from decimal import Decimal
from threading import Barrier

import pytest
from sqlalchemy import func, select

from test_payment_pin_postgres import pg
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.funding import OfficialFundingConfig
from app.modules.wallet.manual_payouts import ManualPayoutPolicy, ManualPayoutService
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.models import WalletControl, WalletConversion, WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.service import WalletLedger


@pytest.fixture
def payout(pg):
    from coincurve import PrivateKey
    from app.integrations.tron.message_signature import address_from_public_key
    pin, factory, claims, now = pg
    pin.setup(claims=claims, pin='012345', login_password='test-password-only', idempotency_key='setup')
    target, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as session:
        session.add(WalletControl(id='global', withdrawals_paused=False))
        session.add(WalletAddressOwner(address=target, user_id='user', created_at=now))
        session.flush()
        session.add(WalletBinding(id='binding', user_id='user', address=target, version=1, status='ACTIVE',
            created_at=now, activated_at=now, effective_from_block=101, barrier_height=100,
            barrier_block_id='a'*64, barrier_source_ids=['fixture'], barrier_observed_at=now))
        session.add(WalletBindingState(user_id='user', version=1, active_binding_id='binding'))
    LedgerService(factory).adjust(user_id='user', amount=Decimal('100'), actor_id='user',
        reason_code='TEST_FUND', idempotency_key='fund')
    with factory.begin() as session:
        session.add(RedeemabilityReserve(id='global', eligible_usdt=Decimal('100'), usdt_liability=Decimal('0'),
            version=1, pending_payouts=0, outgoing_restricted=False, observed_at=now))
    service = ManualPayoutService(factory, official_config=OfficialFundingConfig(official, 'fixture'),
        policy=ManualPayoutPolicy('fixture', timedelta(minutes=5), Decimal('100'), Decimal('500'), Decimal('500')),
        owner_admin_id='user', mfa_verifier=lambda **kw: True, finality=None, clock=pin.clock)
    service.user_mfa_required = False
    service.conversions_enabled = True
    yield service, pin, factory, claims


def create_intent(payout, amount='10.000000', key='request'):
    service, pin, _, claims = payout
    quote = service.quote(user_id='user', amount=amount, expected_binding_version=1,
        funding_asset='CAIBI', idempotency_key='quote-'+key)
    ticket = pin.authorize(claims=claims, pin='012345', action='wallet.payout.create',
        payload={'quote_id': quote['id']}, idempotency_key=key)['authorization']
    return dict(user_id='user', session_id='family', mfa_proof=None, quote_id=quote['id'],
        idempotency_key=key, claims=claims, payment_authorization=ticket)


def test_concurrent_payout_same_intent_and_cancel_append_once(payout):
    service, _, factory, _ = payout
    args = create_intent(payout)
    barrier = Barrier(2)
    def submit(_):
        barrier.wait(timeout=10)
        return service.request(**args)
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(submit, range(2)))
    assert results[0] == results[1]
    assert LedgerService(factory).balance('user') == Decimal('90')
    assert WalletLedger(factory).balance('HOLD:user') == Decimal('10')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(ManualPayoutOrder)) == 1
        assert session.scalar(select(func.count()).select_from(WalletConversion)) == 1
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction).where(
            WalletLedgerTransaction.scope == 'wallet.manual_hold')) == 1
    barrier = Barrier(2)
    def cancel(_):
        barrier.wait(timeout=10)
        return service.cancel(user_id='user', order_id=results[0]['id'], idempotency_key='cancel')
    with ThreadPoolExecutor(max_workers=2) as executor:
        cancelled = list(executor.map(cancel, range(2)))
    assert cancelled[0] == cancelled[1]
    assert LedgerService(factory).balance('user') == Decimal('100')
    assert WalletLedger(factory).balance('HOLD:user') == 0
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletConversion)) == 2
        for scope in ('wallet.manual_release', 'wallet.conversion_reversal'):
            assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction).where(
                WalletLedgerTransaction.scope == scope)) == 1
        assert session.scalar(select(func.count()).select_from(LedgerTransaction).where(
            LedgerTransaction.scope == 'wallet.conversion_reversal')) == 1
        assert session.scalar(select(func.sum(LedgerEntry.amount))) == 0
        assert session.scalar(select(func.sum(WalletLedgerEntry.amount))) == 0


def test_concurrent_distinct_payouts_cannot_overspend_caibi(payout):
    service, _, factory, _ = payout
    intents = [create_intent(payout, amount='80.000000', key=f'request-{index}') for index in range(2)]
    barrier = Barrier(2)
    def submit(args):
        barrier.wait(timeout=10)
        try:
            return service.request(**args)['status']
        except ValueError as error:
            assert 'insufficient balance' in str(error)
            return 'INSUFFICIENT'
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(submit, intents))
    assert sorted(results) == ['INSUFFICIENT', 'REQUESTED']
    assert LedgerService(factory).balance('user') == Decimal('20')
    assert WalletLedger(factory).balance('HOLD:user') == Decimal('80')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(ManualPayoutOrder)) == 1
        assert session.scalar(select(func.count()).select_from(WalletConversion)) == 1
