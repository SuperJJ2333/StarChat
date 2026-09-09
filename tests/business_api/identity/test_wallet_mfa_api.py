from datetime import datetime, timezone

from cryptography.fernet import Fernet
from fastapi import FastAPI
from fastapi.testclient import TestClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.core.rate_limits import NoopRateLimiter
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.identity.totp import TotpService


@pytest.fixture
def setup():
    from app.api.wallet_mfa import create_wallet_mfa_router
    engine = create_engine('sqlite://', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='user', username='user', username_normalized='user', email='u@example.test',
            email_normalized='u@example.test', password_hash=PasswordHasher().hash('test-password-only'),
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    def build(configured=True):
        settings = Settings(_env_file=None, environment='test', jwt_secret='mfa-test-secret-'*4,
            totp_issuer='Wallet Test', wallet_totp_encryption_key=Fernet.generate_key().decode() if configured else None)
        app = FastAPI()
        install_error_handlers(app)
        app.include_router(create_wallet_mfa_router(settings, factory, NoopRateLimiter()))
        pair = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(
            user_id='user', device_key='test', display_name='test')
        return TestClient(app), {'Authorization': 'Bearer '+pair.access_token}, settings
    yield build
    engine.dispose()


def test_mfa_api_requires_session_and_explicit_key(setup):
    client, headers, _ = setup(False)
    assert client.get('/security/mfa').status_code == 401
    response = client.get('/security/mfa', headers=headers)
    assert response.status_code == 200
    assert response.json() == {'configured': False, 'enabled': False, 'enrolled_at': None, 'pending_credential_id': None}
    assert client.post('/security/mfa/enroll', headers=headers, json={'password':'test-password-only'}).status_code == 503


def test_mfa_api_enrollment_real_code_and_no_cache(setup):
    client, headers, _ = setup()
    response = client.post('/security/mfa/enroll', headers=headers, json={'password':'test-password-only'})
    assert response.status_code == 201
    assert response.headers['cache-control'] == 'no-store'
    result = response.json()
    assert result['provisioning_uri'].startswith('otpauth://totp/')
    assert result['secret'] in result['provisioning_uri']
    code = TotpService.code_at(result['secret'], datetime.now(timezone.utc))
    response = client.post('/security/mfa/enable', headers=headers,
        json={'credential_id':result['credential_id'], 'code':code})
    assert response.status_code == 200
    assert response.json()['enabled'] is True
    status = client.get('/security/mfa', headers=headers)
    assert status.json()['enabled'] is True
    assert result['secret'] not in status.text


def test_mfa_api_rejects_client_identity_and_masks_validation(setup):
    client, headers, _ = setup()
    response = client.post('/security/mfa/enroll', headers=headers,
        json={'password':'sensitive-test-password', 'user_id':'victim'})
    assert response.status_code == 422
    assert 'sensitive-test-password' not in response.text


def test_mfa_key_validated_without_repr_leak():
    with pytest.raises(ValueError):
        Settings(_env_file=None, wallet_totp_encryption_key='invalid')
    key = Fernet.generate_key().decode()
    settings = Settings(_env_file=None, wallet_totp_encryption_key=key, totp_issuer='Test')
    assert key not in repr(settings)
    with pytest.raises(ValueError):
        Settings(_env_file=None, wallet_totp_encryption_key=key, totp_issuer=None)


@pytest.mark.parametrize('enabled', [False, True])
def test_missing_key_reports_real_credential_and_only_aborts_pending(setup, enabled):
    client, headers, _ = setup()
    enrollment = client.post('/security/mfa/enroll', headers=headers,
        json={'password': 'test-password-only'}).json()
    if enabled:
        assert client.post('/security/mfa/enable', headers=headers, json={
            'credential_id': enrollment['credential_id'],
            'code': TotpService.code_at(enrollment['secret'], datetime.now(timezone.utc))}).status_code == 200
    client, headers, _ = setup(False)
    response = client.get('/security/mfa', headers=headers)
    assert response.json()['configured'] is False
    assert response.json()['enabled'] is enabled
    assert response.json()['enrolled_at'] is not None
    assert response.json()['pending_credential_id'] == (None if enabled else enrollment['credential_id'])
    assert enrollment['secret'] not in response.text
    assert response.headers['cache-control'] == 'no-store'
    assert client.post('/security/mfa/enable', headers=headers, json={
        'credential_id': enrollment['credential_id'], 'code': '123456'}).status_code == 503
    assert client.post('/security/mfa/enroll', headers=headers,
        json={'password': 'test-password-only'}).status_code == 503
    body = {'credential_id': enrollment['credential_id'], 'password': 'wrong-password'}
    assert client.post('/security/mfa/abort-pending', headers=headers, json=body).status_code == 401
    body['password'] = 'test-password-only'
    assert client.post('/security/mfa/abort-pending', headers=headers, json=body).status_code == (409 if enabled else 200)
    status = client.get('/security/mfa', headers=headers).json()
    assert status['enabled'] is enabled
    assert status['pending_credential_id'] is None
