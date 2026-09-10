from types import SimpleNamespace
from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest

from app.core.config import Settings
from app.core.errors import install_error_handlers
from app.modules.identity.tokens import TokenService
from test_manual_payouts import core  # noqa: F401


@pytest.fixture
def api(core):
    from app.api.manual_wallet import create_manual_wallet_router
    from app.api.payment_pin import create_payment_pin_router
    settings = Settings(_env_file=None, environment='test', jwt_secret='manual-route-key-'*4)
    runtime = SimpleNamespace(funds_enabled=True, payouts=core[0], intents=None)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_manual_wallet_router(settings, core[1], runtime=runtime))
    app.include_router(create_payment_pin_router(settings, core[1], None))
    core[0].payment_pin.clock = lambda: datetime.now(timezone.utc)
    tokens = TokenService(core[1], jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    headers = {}
    for user in ['alice', 'owner', 'bob']:
        pair = tokens.issue_pair(user_id=user, device_key=user, display_name='test')
        headers[user] = {'Authorization': 'Bearer '+pair.access_token, 'Idempotency-Key': 'test'}
    return TestClient(app), headers, runtime


def authorize_payout(client, headers, quote_id):
    result = client.post('/payment-pin/authorize', headers=headers['alice'], json={
        'pin': '654321', 'action': 'wallet.payout.create', 'payload': {'quote_id': quote_id},
        'idempotency_key': headers['alice']['Idempotency-Key']})
    assert result.status_code == 200
    return result.json()['authorization']


def legacy_quote(core, api):
    from decimal import Decimal
    from uuid import uuid4
    from app.modules.wallet.manual_payout_models import ManualPayoutQuote, ManualPayoutCommand
    from app.modules.wallet.manual_payouts import _digest
    # Build a historical-format fixture at insertion, never update immutable rows.
    template = core[0].quote(user_id='alice', amount='10.000000',
        expected_binding_version=1, idempotency_key='fixture-template')
    snapshot = {key: value for key, value in template.items() if key not in {
        'id', 'digest', 'funding_asset', 'funding_amount', 'conversion_rate', 'conversion_fee', 'cancellation_asset'}}
    identifier = str(uuid4())
    persisted = dict(snapshot, id=identifier, digest=_digest(snapshot))
    with core[1].begin() as session:
        session.add(ManualPayoutQuote(id=identifier, user_id='alice', amount=Decimal('10'),
            snapshot=snapshot, digest=persisted['digest'], created_at=datetime.fromisoformat(snapshot['created_at']),
            expires_at=datetime.fromisoformat(snapshot['expires_at'])))
        session.add(ManualPayoutCommand(id=str(uuid4()), actor_id='alice', operation='QUOTE',
            idempotency_key='test', digest=_digest(dict(amount='10.000000', binding_version=1)),
            response=persisted, created_at=datetime.fromisoformat(snapshot['created_at'])))
    return persisted


def test_legacy_quote_status_supplies_usdt_amount_without_mutating_snapshot(core, api):
    from app.modules.wallet.manual_payout_models import ManualPayoutQuote
    original = legacy_quote(core, api)
    client, headers, _ = api
    response = client.get('/manual/payout-quotes/'+original['id'], headers=headers['alice'])
    assert response.status_code == 200
    assert response.json()['funding_asset'] == 'USDT'
    assert response.json()['funding_amount'] == '10.000000'
    assert response.json()['digest'] == original['digest']
    with core[1]() as session:
        row = session.get(ManualPayoutQuote, original['id'])
        assert 'funding_amount' not in row.snapshot
        assert row.digest == original['digest']


@pytest.mark.parametrize('enabled', [True, False])
def test_legacy_quote_replay_supplies_usdt_amount_without_rewriting_command(core, api, enabled):
    from sqlalchemy import select
    from app.modules.wallet.manual_payout_models import ManualPayoutCommand
    original = legacy_quote(core, api)
    client, headers, runtime = api
    runtime.funds_enabled = enabled
    response = client.post('/manual/payout-quotes', headers=headers['alice'],
        json={'amount': '10.000000', 'expected_binding_version': 1})
    assert response.status_code == 201
    assert response.json()['funding_amount'] == '10.000000'
    assert response.json()['digest'] == original['digest']
    with core[1]() as session:
        command = session.scalar(select(ManualPayoutCommand).where(ManualPayoutCommand.operation == 'QUOTE',
            ManualPayoutCommand.idempotency_key == 'test'))
        assert command.response == original


def test_caibi_quote_projection_does_not_guess_missing_funding_amount(core, api):
    from app.api.manual_wallet import QuoteView
    from pydantic import ValidationError
    original = legacy_quote(core, api)
    with pytest.raises(ValidationError):
        QuoteView.model_validate(dict(original, funding_asset='CAIBI'))


def test_manual_api_gates_and_rejects_arbitrary_destination(api):
    client, headers, runtime = api
    assert client.post('/manual/payout-quotes', json={}).status_code == 401
    body = {'amount':'10.000000', 'expected_binding_version':1}
    assert client.post('/manual/payout-quotes', headers=headers['alice'], json=body|{'address':'arbitrary'}).status_code == 422
    assert client.post('/manual/payout-quotes', headers=headers['alice'], json=body|{'amount':10.0}).status_code == 422
    runtime.funds_enabled = False
    assert client.post('/manual/payout-quotes', headers=headers['alice'], json=body).status_code == 503


@pytest.mark.parametrize('user', ['alice', 'owner'])
@pytest.mark.parametrize('path', ['/manual/deposit-intents', '/manual/payout-quotes'])
@pytest.mark.parametrize('field', ['official_address', 'official_config_version'])
def test_request_cannot_override_server_official_wallet(api, user, path, field):
    client, headers, _ = api
    response = client.post(path, headers=headers[user], json={
        'amount': '10.000000', 'expected_binding_version': 1, field: 'untrusted-override'})
    assert response.status_code == 422


def test_manual_api_actual_user_owner_claim_and_visibility(api):
    client, headers, _ = api
    quote = client.post('/manual/payout-quotes', headers=headers['alice'],
        json={'amount':'10.000000','expected_binding_version':1})
    assert quote.status_code == 201
    assert quote.headers['cache-control'] == 'no-store'
    order = client.post('/manual/payouts', headers=headers['alice'],
        json={'quote_id':quote.json()['id'],'mfa_proof':'123456',
            'payment_authorization': authorize_payout(client, headers, quote.json()['id'])})
    assert order.status_code == 201
    identifier = order.json()['id']
    assert client.get('/manual/payouts/'+identifier, headers=headers['bob']).status_code == 404
    body = {'expected_digest':order.json()['digest'], 'mfa_proof':'123456'}
    assert client.post('/manual/payouts/'+identifier+'/claim', headers=headers['alice'], json=body).status_code == 403
    claimed = client.post('/manual/payouts/'+identifier+'/claim', headers=headers['owner'], json=body)
    assert claimed.status_code == 200
    assert claimed.json()['status'] == 'CLAIMED'
    assert 'instructions' in claimed.json()
    assert client.post('/manual/payouts/'+identifier+'/cancel', headers=headers['alice']).status_code == 409


def test_pending_cancel_still_works_after_funds_pause(api):
    client, headers, runtime = api
    quote = client.post('/manual/payout-quotes', headers=headers['alice'],
        json={'amount':'10.000000','expected_binding_version':1}).json()
    order = client.post('/manual/payouts', headers=headers['alice'],
        json={'quote_id':quote['id'],'mfa_proof':'123456',
            'payment_authorization': authorize_payout(client, headers, quote['id'])}).json()
    runtime.funds_enabled = False
    response = client.post('/manual/payouts/'+order['id']+'/cancel', headers=headers['alice'])
    assert response.status_code == 200
    assert response.json()['status'] == 'CANCELLED'


def test_current_deposit_route_uses_authenticated_user_while_funds_paused(api):
    client, headers, runtime = api
    callers = []
    def current(*, user_id):
        callers.append(user_id)
        return None
    runtime.intents = SimpleNamespace(current=current)
    runtime.funds_enabled = False
    assert client.get('/manual/deposit-intents/current').status_code == 401
    response = client.get('/manual/deposit-intents/current', headers=headers['alice'])
    assert response.status_code == 200 and response.json() == {'intent':None}
    assert response.headers['cache-control'] == 'no-store'
    assert callers == ['alice']


def test_main_exposes_manual_contract_without_enabling_funds():
    from app.main import create_app
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://')
    app = create_app(settings)
    paths = app.openapi()['paths']
    assert '/api/v1/wallet/manual/payouts' in paths
    assert '/api/v1/wallet/manual/deposit-intents' in paths
    assert app.state.manual_wallet_runtime is None


def test_manual_wallet_flags_match_bound_only_disabled_conversion(core, api):
    from app.api.wallet import create_wallet_router
    from app.modules.wallet.binding import WalletBindingService
    _, headers, runtime = api
    runtime.binding = WalletBindingService(core[1], domain='wallet.example.test')
    runtime.conversions_enabled = False
    runtime.deposits_enabled = runtime.payout_requests_enabled = runtime.payout_execution_enabled = True
    runtime.receipts = SimpleNamespace(reserve_policy='full_backing')
    settings = Settings(_env_file=None, environment='test', jwt_secret='manual-route-key-'*4,
        wallet_conversions_enabled=True)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_wallet_router(settings, core[1], manual_runtime=runtime))
    client = TestClient(app)
    config = client.get('/wallet/config', headers=headers['alice']).json()
    assert config['binding_required'] is True
    assert config['conversion_enabled'] is False
    balances = client.get('/wallet/balances/me', headers=headers['alice']).json()
    assert balances['conversion_enabled'] is False
