from datetime import datetime, timezone
from decimal import Decimal

from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine, select, func
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.core.rate_limits import NoopRateLimiter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.ledger.service import LedgerService


@pytest.fixture
def setup():
    from app.api.payment_pin import create_payment_pin_router
    from app.api.transfer import create_transfer_router
    from app.api.redpacket import create_redpacket_router
    from app.api.ledger import create_ledger_router
    engine = create_engine('sqlite://', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='user', username='user', username_normalized='user', email='u@example.test',
            email_normalized='u@example.test', password_hash=PasswordHasher().hash('test-password-only'),
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    ledger = LedgerService(factory)
    ledger.adjust(user_id='user', amount=Decimal('100'), actor_id='fixture', reason_code='TEST_FUND', idempotency_key='fund')
    def build(require_all=False):
        settings = Settings(_env_file=None, environment='test', jwt_secret='payment-pin-api-test-secret-'*3, payment_pin_require_all=require_all)
        app = FastAPI()
        install_error_handlers(app)
        app.include_router(create_payment_pin_router(settings, factory, NoopRateLimiter()))
        app.include_router(create_transfer_router(settings, factory))
        app.include_router(create_redpacket_router(settings, factory))
        app.include_router(create_ledger_router(settings, factory))
        pair = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(user_id='user', device_key='test', display_name='test')
        return TestClient(app), {'Authorization': 'Bearer '+pair.access_token, 'Idempotency-Key': 'payment-key'}
    yield build, factory, ledger
    engine.dispose()


def enroll(client, headers):
    result = client.post('/payment-pin/setup', headers=headers, json=dict(pin='012345', login_password='test-password-only'))
    assert result.status_code == 200, result.text
    assert result.headers['cache-control'] == 'no-store'


def test_setup_status_and_secret_validation(setup):
    build, _, _ = setup
    client, headers = build()
    assert client.get('/payment-pin/status').status_code == 401
    assert not client.get('/payment-pin/status', headers=headers).json()['configured']
    for pin in [123456, '12345', '1234567', '１２３４５６']:
        response = client.post('/payment-pin/setup', headers=headers, json=dict(pin=pin, login_password='test-password-only'))
        assert response.status_code == 422
        assert 'test-password-only' not in response.text
    enroll(client, headers)
    assert client.get('/payment-pin/status', headers=headers).json()['configured']


@pytest.mark.parametrize('path,payload,action', [
    ('/chat-transfers', dict(receiver_id='other', amount='1'), 'chat_transfer.create'),
    ('/red-packets', dict(recipient_id='other', mode='EQUAL', total='1', share_count=1), 'red_packet.create'),
    ('/red-packets', dict(room_id='!test:example', mode='RANDOM', total='1', share_count=2), 'red_packet.create'),
    ('/red-packets', dict(room_id='!test:example', recipient_id='other', mode='EXCLUSIVE', total='1', share_count=1), 'red_packet.create'),
])
def test_real_create_api_pin_gate_bound_authorization_and_retry(setup, path, payload, action):
    build, factory, ledger = setup
    client, headers = build()
    enroll(client, headers)
    blocked = client.post(path, headers=headers, json=payload)
    assert blocked.status_code == 403, blocked.text
    assert ledger.balance('user') == Decimal('100')
    auth = client.post('/payment-pin/authorize', headers=headers, json=dict(pin='012345', action=action, payload=payload, idempotency_key='payment-key'))
    assert auth.status_code == 200, auth.text
    ticket = auth.json()['authorization']
    first = client.post(path, headers=headers, json={**payload, 'payment_authorization': ticket})
    assert first.status_code == 201, first.text
    second = client.post(path, headers=headers, json={**payload, 'payment_authorization': ticket})
    assert second.status_code == 201, second.text
    assert first.json()['id'] == second.json()['id']
    assert ledger.balance('user') == Decimal('98.99' if action == 'chat_transfer.create' else '99')
    other_client, other_headers = build()
    replay = other_client.post(path, headers=other_headers, json={**payload, 'payment_authorization': ticket})
    assert replay.status_code == 403


def test_legacy_endpoint_cannot_bypass_configured_account(setup):
    build, _, ledger = setup
    client, headers = build()
    enroll(client, headers)
    result = client.post('/ledger/transfers', headers=headers, json=dict(receiver_id='other', amount='1'))
    assert result.status_code == 403
    assert result.json()['error']['code'] == 'PAYMENT_PIN_REQUIRED'
    assert ledger.balance('user') == Decimal('100')


def test_rollout_gate_only_controls_unconfigured_accounts(setup):
    build, _, ledger = setup
    client, headers = build(True)
    for path, payload in [('/ledger/transfers', dict(receiver_id='other', amount='1')), ('/chat-transfers', dict(receiver_id='other', amount='1')), ('/red-packets', dict(mode='EQUAL', recipient_id='other', total='1', share_count=1))]:
        response = client.post(path, headers=headers, json=payload)
        assert response.status_code in (403, 409)
        assert response.json()['error']['code'] == 'PAYMENT_PIN_SETUP_REQUIRED'
    assert ledger.balance('user') == Decimal('100')
    client, headers = build(False)
    assert client.post('/chat-transfers', headers=headers, json=dict(receiver_id='other', amount='1')).status_code == 201


def test_lost_success_response_can_reauthorize_same_intent(setup):
    build, _, ledger = setup
    client, headers = build()
    enroll(client, headers)
    payload = dict(receiver_id='other', amount='1')
    auth_body = dict(pin='012345', action='chat_transfer.create', payload=payload, idempotency_key='payment-key')
    ids = []
    for _ in range(2):
        ticket = client.post('/payment-pin/authorize', headers=headers, json=auth_body).json()['authorization']
        response = client.post('/chat-transfers', headers=headers, json={**payload, 'payment_authorization': ticket})
        assert response.status_code == 201
        ids.append(response.json()['id'])
    assert ids[0] == ids[1]
    assert ledger.balance('user') == Decimal('98.99')
