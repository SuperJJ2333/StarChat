"""Lost response recovery reads committed commands without reopening money gates."""
from datetime import timedelta

import pytest
from sqlalchemy import func, select

from app.core.outbox import OutboxEvent
from app.core.errors import AppError
from app.modules.audit.models import AuditEvent
from app.modules.wallet.funding import DepositIntentService
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.manual_payout_models import ManualPayoutCommand, ManualPayoutOrder
from app.modules.wallet.models import WalletLedgerTransaction
from test_manual_wallet_api import api, core  # noqa: F401


def command(api, core, kind):
    client, headers, runtime = api
    runtime.intents = DepositIntentService(core[1], official_config=core[0].official_config,
        intent_ttl=timedelta(minutes=20), clock=lambda: core[2][0])
    body = {'amount': '10.000000', 'expected_binding_version': 1}
    path = '/manual/deposit-intents' if kind == 'deposit' else '/manual/payout-quotes'
    if kind == 'request':
        quote = client.post(path, headers=headers['alice'], json=body)
        assert quote.status_code == 201
        path, body = '/manual/payouts', {'quote_id': quote.json()['id'], 'mfa_proof': '123456'}
    response = client.post(path, headers=headers['alice'], json=body)
    assert response.status_code == 201
    runtime.funds_enabled = False
    runtime.deposits_enabled = runtime.payout_requests_enabled = runtime.payout_execution_enabled = False
    return path, body, response.json()


def counts(core):
    with core[1]() as session:
        return tuple(session.scalar(select(func.count()).select_from(model)) for model in
            (AuditEvent, OutboxEvent, DepositIntent, ManualPayoutCommand, ManualPayoutOrder, WalletLedgerTransaction))


@pytest.mark.parametrize('kind', ['deposit', 'quote', 'request'])
def test_closed_capability_recovers_exact_committed_response_without_writes(api, core, kind):
    path, body, original = command(api, core, kind)
    before = counts(core)
    if kind == 'request':
        core[0].mfa_verifier = lambda **kwargs: pytest.fail('read-only recovery must not consume MFA')
    response = api[0].post(path, headers=api[1]['alice'], json=body)
    assert response.status_code == 201
    assert response.json() == original
    assert response.headers['cache-control'] == 'no-store'
    assert counts(core) == before


@pytest.mark.parametrize('kind', ['deposit', 'quote', 'request'])
def test_recovery_preserves_conflict_isolation_and_closed_new_command_gate(api, core, kind):
    path, body, _ = command(api, core, kind)
    before = counts(core)
    changed = body | ({'quote_id': 'different-quote'} if kind == 'request' else {'amount': '11.000000'})
    assert api[0].post(path, headers=api[1]['alice'], json=changed).status_code == 409
    assert api[0].post(path, headers=api[1]['bob'], json=body).status_code == 503
    assert api[0].post(path, headers=api[1]['alice'] | {'Idempotency-Key': 'new-key'}, json=body).status_code == 503
    assert api[0].post(path, json=body).status_code == 401
    assert counts(core) == before


def test_closed_execution_gate_never_recovers_claim_instructions(api, core):
    path, body, original = command(api, core, 'request')
    runtime = api[2]
    runtime.payout_execution_enabled = True
    url = '/manual/payouts/' + original['id'] + '/claim'
    claim_body = {'expected_digest': original['digest'], 'mfa_proof': '123456'}
    assert api[0].post(url, headers=api[1]['owner'], json=claim_body).status_code == 200
    runtime.payout_execution_enabled = False
    before = counts(core)
    response = api[0].post(url, headers=api[1]['owner'], json=claim_body)
    assert response.status_code == 503
    assert 'instructions' not in response.json()
    assert counts(core) == before


def test_expired_deposit_recovery_does_not_persist_expiration_or_replacement(api, core):
    path, body, original = command(api, core, 'deposit')
    core[2][0] += timedelta(minutes=21)
    before = counts(core)
    response = api[0].post(path, headers=api[1]['alice'], json=body)
    assert response.status_code == 201
    assert response.json() == original
    with core[1]() as session:
        row = session.get(DepositIntent, original['id'])
        assert row.status == 'OPEN' and row.closed_at is None
    assert counts(core) == before


@pytest.mark.parametrize('kind', ['deposit', 'quote', 'request'])
def test_recovery_application_service_rechecks_active_actor(api, core, kind):
    from app.modules.identity.models import User, AccountStatus
    _, body, _ = command(api, core, kind)
    with core[1].begin() as session:
        session.get(User, 'alice').status = AccountStatus.SUSPENDED
    before = counts(core)
    with pytest.raises(AppError) as rejected:
        if kind == 'deposit':
            api[2].intents.recover(user_id='alice', expected_amount=body['amount'],
                expected_binding_version=body['expected_binding_version'], idempotency_key='test')
        else:
            core[0].recover(user_id='alice', operation='QUOTE' if kind == 'quote' else 'REQUEST',
                payload={'amount': body['amount'], 'binding_version': 1} if kind == 'quote' else {'quote_id': body['quote_id']},
                idempotency_key='test')
    assert rejected.value.code == 'WALLET_ACCOUNT_UNAVAILABLE'
    assert counts(core) == before


def test_recovery_application_service_cannot_select_claim_command(core):
    before = counts(core)
    with pytest.raises(AppError, match='RECOVERY_OPERATION_INVALID'):
        core[0].recover(user_id='owner', operation='CLAIM', idempotency_key='test',
            payload={'order_id': 'order', 'expected_digest': 'digest'})
    assert counts(core) == before
