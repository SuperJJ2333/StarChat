from datetime import timedelta

import jwt
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app
from app.modules.identity.enums import HoldType
from app.modules.identity.models import SecurityHold
pytest_plugins = ('tests.business_api.identity.test_wallet_access_grant',)


def test_context_openapi_types_wallet_owner_read(grant_context):
    _, factory, _, _, _ = grant_context
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        jwt_secret='test-wallet-access-app-secret-at-least-32-bytes',
        wallet_access_grant_enabled=True, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_access_policy_version='v1')
    schema = create_app(settings, session_factory=factory).openapi()
    response_schema = schema['paths']['/api/v1/admin/context']['get']['responses']['200'][
        'content']['application/json']['schema']
    context_schema = schema['components']['schemas'][response_schema['$ref'].rsplit('/', 1)[-1]]
    capability_ref = context_schema['properties']['capabilities']['$ref']
    capabilities = schema['components']['schemas'][capability_ref.rsplit('/', 1)[-1]]
    assert capabilities['properties']['wallet_owner_read']['type'] == 'boolean'
    assert 'wallet_owner_read' in capabilities['required']


def test_context_wallet_capability_uses_live_owner_read_authorization(grant_context):
    _, factory, now, claims, _ = grant_context
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        jwt_secret='test-wallet-access-app-secret-at-least-32-bytes',
        wallet_access_grant_enabled=True, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_access_policy_version='v1')
    app = create_app(settings, session_factory=factory)
    settings.wallet_real_mode = 'manual_tron'
    client = TestClient(app)
    token = jwt.encode(claims | {'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    headers = {'Authorization': 'Bearer ' + token}

    allowed = client.get('/api/v1/admin/context', headers=headers)
    assert allowed.status_code == 200, allowed.text
    assert allowed.json()['capabilities']['wallet_owner_read'] is True

    settings.wallet_manual_owner_admin_id = 'other-admin'
    non_owner = client.get('/api/v1/admin/context', headers=headers)
    assert non_owner.status_code == 200, non_owner.text
    assert non_owner.json()['capabilities']['wallet_owner_read'] is False

    settings.wallet_manual_owner_admin_id = 'owner'
    with factory.begin() as session:
        session.add(SecurityHold(id='password-hold', user_id='owner',
            hold_type=HoldType.WITHDRAWAL, reason_code='PASSWORD_RESET',
            starts_at=now[0], ends_at=now[0] + timedelta(hours=1), created_at=now[0]))
    held = client.get('/api/v1/admin/context', headers=headers)
    assert held.status_code == 200, held.text
    assert held.json()['capabilities']['wallet_owner_read'] is False


def test_context_wallet_capability_preserves_legacy_flag_off_menu(grant_context):
    _, factory, _, claims, _ = grant_context
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        jwt_secret='test-wallet-access-app-secret-at-least-32-bytes',
        wallet_access_grant_enabled=False, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_access_policy_version='v1')
    app = create_app(settings, session_factory=factory)
    settings.wallet_real_mode = 'manual_tron'
    token = jwt.encode(claims | {'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    response = TestClient(app).get('/api/v1/admin/context',
        headers={'Authorization': 'Bearer ' + token})
    assert response.status_code == 200, response.text
    assert response.json()['capabilities']['wallet_owner_read'] is True
