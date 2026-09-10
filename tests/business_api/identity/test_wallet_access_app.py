from datetime import timedelta
import jwt
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app
from app.modules.identity.models import AdminSession
from app.modules.identity.wallet_grant_models import WalletAccessGrant
from tests.business_api.identity.test_wallet_access_grant import grant_context


def test_real_app_blocks_wallet_preload_and_accepts_59_minute_grant(grant_context):
    service, factory, now, claims, source = grant_context
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        jwt_secret='test-wallet-access-app-secret-at-least-32-bytes',
        wallet_access_grant_enabled=True, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_access_policy_version='v1')
    app = create_app(settings, session_factory=factory)
    # Construct the real HTTP application without starting external observer clients.
    settings.wallet_real_mode = 'manual_tron'
    client = TestClient(app)
    token = jwt.encode(claims | {'iss':settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    headers = {'Authorization':'Bearer '+token}
    with factory.begin() as session:
        session.get(AdminSession, 'owner').authenticated_at = now[0]-timedelta(minutes=70)
    context = client.get('/api/v1/admin/context', headers=headers)
    assert context.status_code == 200
    assert 'wallet' not in context.json()['modules']
    denied = client.get('/api/v1/admin/modules/wallet', headers=headers)
    assert denied.status_code == 403
    assert denied.json()['error']['code'] == 'WALLET_ACCESS_REQUIRED'
    # Bootstrap metadata stays accessible without sensitive wallet content.
    metadata = client.get('/api/v1/admin/wallet/security', headers=headers)
    assert metadata.status_code == 200
    assert metadata.json()['configured'] is True
    issued = client.post('/api/v1/wallet/manual/access/verify', headers=headers,
        json={'operation_password':'operation-password-123'})
    assert issued.status_code == 200
    with factory.begin() as session:
        row = session.get(WalletAccessGrant, 'family')
        row.verified_at = now[0]-timedelta(minutes=59)
        row.expires_at = now[0]+timedelta(minutes=1)
    assert client.get('/api/v1/admin/modules/wallet', headers=headers).status_code == 200
    assert client.get('/api/v1/admin/wallet/security', headers=headers).status_code == 200
    assert client.post('/api/v1/wallet/manual/access/revoke', headers=headers).status_code == 200
    assert client.get('/api/v1/admin/modules/wallet', headers=headers).status_code == 403
    assert client.get('/api/v1/admin/session', headers=headers).status_code == 200
