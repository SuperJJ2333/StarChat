"""Isolated regression coverage for ADR-0068; no chain/provider financial writes."""
import hashlib
from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.payment_pin import PaymentPinService
from app.modules.identity.payment_pin_models import PaymentPinAuthorization
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.service import LedgerService
from app.modules.wallet.models import WalletConversion
from test_manual_payouts import core, quote, request


def funded(core):
    service, factory = core[:2]
    service.conversions_enabled = True
    with factory.begin() as session:
        session.get(RedeemabilityReserve, 'global').eligible_usdt = Decimal('1100')
    LedgerService(factory).post(entries={'alice': Decimal('100'), 'PLATFORM_CLEARING': Decimal('-100')},
        actor_id='alice', reason_code='TEST_FUND', idempotency_key='points', scope='test')
    return quote(core, funding_asset='CAIBI')


def test_caibi_request_atomic_and_idempotent(core):
    q = funded(core)
    order = request(core, q)
    assert order['funding_asset'] == 'CAIBI'
    assert order['funding_amount'] == '10.00'
    assert LedgerService(core[1]).balance('alice') == Decimal('90')
    assert core[5].balance('alice') == Decimal('1000')
    assert core[5].balance('HOLD:alice') == Decimal('10')
    assert request(core, q)['id'] == order['id']
    with core[1]() as session:
        assert len(list(session.scalars(select(WalletConversion)))) == 1


def test_caibi_cancel_returns_source_despite_stale_reserve(core):
    order = request(core, funded(core))
    with core[1].begin() as session:
        session.get(RedeemabilityReserve, 'global').observed_at -= timedelta(hours=1)
    result = core[0].cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel')
    assert result['status'] == 'CANCELLED'
    assert LedgerService(core[1]).balance('alice') == Decimal('100')
    assert core[5].balance('alice') == Decimal('1000')
    assert core[5].balance('HOLD:alice') == 0
    assert core[0].cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel') == result


def test_new_usdt_request_forces_pin_when_require_all_false(core):
    service = core[0]
    service.payment_pin.require_all = False
    q = quote(core)
    with pytest.raises(AppError) as error:
        service.request(user_id='alice', session_id='session', mfa_proof='123456',
            quote_id=q['id'], idempotency_key='no-pin')
    assert error.value.code in {'PAYMENT_PIN_REQUIRED', 'PAYMENT_PIN_SETUP_REQUIRED', 'AUTH_REQUIRED'}
    assert core[5].balance('HOLD:alice') == 0


def test_missing_pin_recovery_probe_does_not_consume_totp(core):
    calls = []
    core[0].mfa_verifier = lambda **kwargs: calls.append(kwargs) or True
    q = quote(core)
    with pytest.raises(AppError) as error:
        core[0].request(user_id='alice', session_id='session', mfa_proof='123456',
            quote_id=q['id'], idempotency_key='probe')
    assert error.value.code == 'PAYMENT_PIN_REQUIRED'
    assert calls == []
    order = request(core, q)
    assert len(calls) == 1
    assert core[0].request(user_id='alice', session_id='session', mfa_proof=None,
        quote_id=q['id'], idempotency_key='r') == order
    assert len(calls) == 1


def test_quote_id_is_part_of_payment_intent():
    assert PaymentPinService.intent_hash('wallet.payout.create', {'quote_id': 'one'}, 'key') != \
        PaymentPinService.intent_hash('wallet.payout.create', {'quote_id': 'two'}, 'key')


def test_fractional_caibi_and_disabled_conversion_fail_closed(core):
    with pytest.raises(AppError):
        quote(core, funding_asset='CAIBI')
    core[0].conversions_enabled = True
    with pytest.raises(AppError):
        quote(core, funding_asset='CAIBI', amount='10.000001')


def test_hold_failure_rolls_back_pin_conversion_and_balances(core, monkeypatch):
    q = funded(core)
    def unavailable(**kwargs):
        raise ValueError('injected hold failure')
    monkeypatch.setattr(core[0].wallet_ledger, 'post', unavailable)
    with pytest.raises(ValueError, match='injected hold failure'):
        request(core, q)
    assert LedgerService(core[1]).balance('alice') == Decimal('100')
    assert core[5].balance('alice') == Decimal('1000')
    assert core[5].balance('HOLD:alice') == 0
    token = core[0].fixture_tickets[('r', q['id'])]
    with core[1]() as session:
        assert list(session.scalars(select(WalletConversion))) == []
        assert session.get(PaymentPinAuthorization, hashlib.sha256(token.encode()).hexdigest()).consumed_at is None
        assert session.get(RedeemabilityReserve, 'global').usdt_liability == Decimal('1000')


def test_accepted_request_recovers_without_new_authorization(core):
    q = funded(core)
    order = request(core, q)
    core[2][0] += timedelta(minutes=10)
    core[0].conversions_enabled = False
    recovered = core[0].request(user_id='alice', session_id='session', mfa_proof=None,
        quote_id=q['id'], idempotency_key='r', payment_authorization=None, claims=core[0].fixture_claims)
    assert recovered == order
    assert LedgerService(core[1]).balance('alice') == Decimal('90')


def test_cancel_restores_only_original_source_with_unrelated_pending_payout(core):
    order = request(core, funded(core))
    with core[1].begin() as session:
        reserve = session.get(RedeemabilityReserve, 'global')
        reserve.observed_at -= timedelta(hours=1)
        reserve.pending_payouts = 1
        reserve.outgoing_restricted = True
        reserve.eligible_usdt = Decimal('0')
    core[0].cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel')
    assert LedgerService(core[1]).balance('alice') == Decimal('100')
    with core[1]() as session:
        reserve = session.get(RedeemabilityReserve, 'global')
        assert reserve.pending_payouts == 1
        assert reserve.eligible_usdt == 0
        assert reserve.usdt_liability == Decimal('1000')


def test_reverse_requires_persisted_matching_usdt_release(core):
    request(core, funded(core))
    with core[1]() as session:
        conversion_id = session.scalar(select(WalletConversion.id))
    with pytest.raises(ValueError, match='release proof'):
        with core[1].begin() as session:
            LedgerService(core[1]).reverse_conversion_debit(session=session, user_id='alice',
                conversion_id=conversion_id, wallet_release_id='not-a-transaction')
    assert LedgerService(core[1]).balance('alice') == Decimal('90')


def test_quote_reader_checks_owner_and_authorization_payload_is_strict(core):
    q = funded(core)
    assert core[0].quote_status(user_id='alice', quote_id=q['id'])['digest'] == q['digest']
    with pytest.raises(AppError) as error:
        core[0].quote_status(user_id='bob', quote_id=q['id'])
    assert error.value.code == 'WALLET_PAYOUT_QUOTE_NOT_FOUND'
    with pytest.raises(AppError):
        PaymentPinService.intent_hash('wallet.payout.create', {'quote_id': q['id'], 'amount': '1'}, 'key')
