"""Review regressions: money writes must match durable business intent."""
from decimal import Decimal

import pytest

from app.core.errors import AppError
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService
from test_manual_payout_rate import core, _caibi_quote, _request, _balance


def _manual(core):
    svc = core[0]
    svc.reserve_policy = svc.wallet_ledger.reserve_policy = 'manual_liquidity'
    return svc


def test_recharge_rejects_nonexistent_ledger_proof(core):
    svc = RechargeService(core[1], ledger=LedgerService(core[1]))
    request = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='submit')
    with pytest.raises(AppError):
        svc.mark_credited(request_id=request['id'], actor_id='owner',
            ledger_transaction_id='nonexistent', final_caibi_amount='71.20',
            final_rate='7.12', idempotency_key='credit')


def test_recharge_submit_replays_same_idempotency_key(core):
    svc = RechargeService(core[1], ledger=LedgerService(core[1]))
    first = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='submit')
    second = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='submit')
    assert first['id'] == second['id']


def test_caibi_quote_applies_maximum_in_usdt_units(core):
    _manual(core)
    quote = _caibi_quote(core, amount='142.400000')
    assert quote['receive'] == '20.000000'  # below 100 USDT cap


def test_sequential_rate_changes_keep_hold_equal_to_final_payable(core):
    svc = _manual(core)
    svc.rate_state['rate'] = Decimal('9')
    quote = _caibi_quote(core, amount='90.000000')
    order = _request(core, quote)
    svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim', mfa_proof='123456')
    for key, rate in [('adjust1', '4.5'), ('adjust2', '3')]:
        adjusted = svc.adjust_rate(admin_id='owner', session_id='session',
            mfa_proof='123456', order_id=order['id'], new_rate=rate,
            reason_code='RATE_REVIEW', idempotency_key=key)
    assert _balance(core, core[1], 'HOLD:alice') == Decimal(adjusted['final_receive'])
    from app.modules.ledger.reserve import approved_unpaid_usdt
    with core[1]() as session:
        assert approved_unpaid_usdt(session) == Decimal(adjusted['final_receive'])
    assert _balance(core, core[1], 'alice') == Decimal('980')
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    with core[1]() as session:
        saved = session.get(ManualPayoutOrder, order['id'])
        assert saved.adjustment_history[-1]['old_rate'] == '4.500000'
    svc.submit_txid(admin_id='owner', order_id=order['id'],
        txid='a' * 64, idempotency_key='txid')
    assert svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
        order_id=order['id'], new_rate='3', reason_code='RATE_REVIEW', idempotency_key='adjust2') == adjusted
    assert _balance(core, core[1], 'HOLD:alice') == Decimal('30')


def test_stale_reference_cannot_be_used_to_lock_payout_settlement(core):
    svc = _manual(core)
    svc.rate_state['stale'] = True
    with pytest.raises(AppError):
        _request(core, _caibi_quote(core))


def test_rate_increase_preserves_user_daily_usdt_limit(core):
    from dataclasses import replace

    svc = _manual(core)
    svc.policy = replace(svc.policy, user_24h=Decimal('20'))
    svc.rate_state['rate'] = Decimal('9')
    order = _request(core, _caibi_quote(core, amount='90.000000'))
    svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim', mfa_proof='123456')
    with pytest.raises(AppError):
        svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
            order_id=order['id'], new_rate='3', reason_code='RATE_REVIEW', idempotency_key='adjust')


def test_cancellation_returns_original_points_and_no_extra_usdt(core):
    svc = _manual(core)
    order = _request(core, _caibi_quote(core))
    first = svc.cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel')
    assert first == svc.cancel(user_id='alice', order_id=order['id'], idempotency_key='cancel')
    assert _balance(core, core[1], 'HOLD:alice') == Decimal('0')
    assert _balance(core, core[1], 'alice') == Decimal('1000')
    assert _balance(core, core[1], 'alice', 'caibi') == Decimal('500')


def test_rate_adjustment_refunds_surplus_to_user(core):
    svc = _manual(core)
    svc.rate_state['rate'] = Decimal('3')
    order = _request(core, _caibi_quote(core, amount='90.000000'))
    svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim', mfa_proof='123456')
    svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
        order_id=order['id'], new_rate='4.5', reason_code='RATE_REVIEW', idempotency_key='adjust')
    assert _balance(core, core[1], 'alice') == Decimal('1010')
    assert _balance(core, core[1], 'HOLD:alice') == Decimal('20')


def test_rate_adjustment_rejects_insufficient_user_funds(core):
    svc = _manual(core)
    order = _request(core, _caibi_quote(core))
    core[5].post(entries={'alice': Decimal('-1000'), 'bob': Decimal('1000')},
        actor_id='alice', reason_code='TEST_SPEND', idempotency_key='spend', scope='test')
    svc.claim(admin_id='owner', session_id='session', order_id=order['id'],
        expected_digest=order['digest'], idempotency_key='claim', mfa_proof='123456')
    with pytest.raises(AppError):
        svc.adjust_rate(admin_id='owner', session_id='session', mfa_proof='123456',
            order_id=order['id'], new_rate='3.56', reason_code='RATE_REVIEW', idempotency_key='adjust')
    assert _balance(core, core[1], 'HOLD:alice') == Decimal('10')


def test_recharge_requires_executed_adjustment_not_just_ledger_post(core):
    ledger = LedgerService(core[1])
    ledger.reserve_policy = 'manual_liquidity'
    svc = RechargeService(core[1], ledger=ledger)
    request = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='submit')
    tx = ledger.adjust(user_id='alice', amount=Decimal('71.20'), actor_id='owner',
        reason_code='RECHARGE_CREDIT', idempotency_key='unapproved')
    with pytest.raises(AppError):
        svc.mark_credited(request_id=request['id'], actor_id='owner', ledger_transaction_id=tx.id,
            final_caibi_amount='71.20', final_rate='7.12', idempotency_key='credit')


def test_recharge_directory_update_missing_entry_does_not_create(core):
    svc = RechargeService(core[1], ledger=LedgerService(core[1]))
    with pytest.raises(AppError) as error:
        svc.upsert_directory_entry(actor_id='owner', entry_id='missing', cs_user_id='owner',
            display_name='Support', payment_address='T' * 34)
    assert error.value.status_code == 404


def test_executed_recharge_proof_consumed_once_and_payload_checked(core):
    from app.modules.ledger.adjustments import AdjustmentWorkflow

    ledger = LedgerService(core[1])
    ledger.reserve_policy = 'manual_liquidity'
    svc = RechargeService(core[1], ledger=ledger)
    workflow = AdjustmentWorkflow(core[1], ledger, admin_threshold=Decimal('10000'))
    workflow.set_policy('owner', per_transaction=Decimal('1000'), per_day=Decimal('10000'), allowed_users={'alice'})
    adjustment = workflow.submit(actor_id='owner', user_id='alice', amount=Decimal('71.20'),
        reason_code='RECHARGE_CREDIT', idempotency_key='adjustment')
    workflow.finance_review(adjustment.id, reviewer_id='bob', approve=True)
    executed = workflow.execute(adjustment.id, actor_id='owner', idempotency_key='execute')
    first = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='first')
    second = svc.submit(user_id='alice', amount_usdt='10', idempotency_key='second')
    payload = dict(actor_id='owner', ledger_transaction_id=executed.ledger_transaction_id,
        final_caibi_amount='71.20', final_rate='7.12', idempotency_key='credit')
    credited = svc.mark_credited(request_id=first['id'], **payload)
    assert credited['status'] == 'CREDITED'
    assert svc.mark_credited(request_id=first['id'], **payload) == credited
    with pytest.raises(AppError) as error:
        svc.mark_credited(request_id=second['id'], **(payload | {'idempotency_key': 'credit2'}))
    assert error.value.code == 'RECHARGE_PROOF_REUSED'
    with pytest.raises(AppError) as error:
        svc.mark_credited(request_id=first['id'], **(payload | {'final_caibi_amount': '72'}))
    assert error.value.code == 'IDEMPOTENCY_KEY_REUSED'
    assert _balance(core, core[1], 'alice', 'caibi') == Decimal('571.20')


def test_recharge_directory_update_requires_admin_and_can_disable(core):
    import asyncio
    from fastapi import FastAPI
    from httpx import ASGITransport, AsyncClient
    from app.api.recharge import create_recharge_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.tokens import TokenService

    svc = RechargeService(core[1], ledger=LedgerService(core[1]))
    created = svc.upsert_directory_entry(actor_id='owner', cs_user_id='owner',
        display_name='Support', payment_address='T' * 34)
    settings = Settings(_env_file=None, environment='test', jwt_secret='test-secret-at-least-thirty-two-bytes')
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_recharge_router(settings, core[1], recharge_service=svc))
    tokens = TokenService(core[1], jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    owner = tokens.issue_pair(user_id='owner', device_key='admin', display_name='admin').access_token
    alice = tokens.issue_pair(user_id='alice', device_key='user', display_name='user').access_token
    body = dict(cs_user_id='owner', display_name='Support', payment_address='T' * 34, enabled=False)
    async def calls():
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            denied = await client.put('/recharge/admin/directory/'+created['id'], json=body,
                headers={'Authorization': 'Bearer '+alice})
            response = await client.put('/recharge/admin/directory/'+created['id'], json=body,
                headers={'Authorization': 'Bearer '+owner})
            admin_denied = await client.get('/recharge/admin/directory',
                headers={'Authorization': 'Bearer '+alice})
            admin_list = await client.get('/recharge/admin/directory',
                headers={'Authorization': 'Bearer '+owner})
            public_list = await client.get('/recharge/directory',
                headers={'Authorization': 'Bearer '+alice})
        return denied, response, admin_denied, admin_list, public_list
    denied, response, admin_denied, admin_list, public_list = asyncio.run(calls())
    assert denied.status_code == 403
    assert response.status_code == 200 and response.json()['id'] == created['id']
    assert svc.directory() == []
    assert admin_denied.status_code == 403
    assert admin_list.status_code == 200
    assert [item['id'] for item in admin_list.json()['items']] == [created['id']]
    assert admin_list.json()['items'][0]['enabled'] is False
    assert public_list.status_code == 200 and public_list.json()['items'] == []
