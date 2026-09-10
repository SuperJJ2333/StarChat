from types import SimpleNamespace

import pytest
from starlette.requests import Request

from app.api import admin_session_boundary as boundary


@pytest.mark.parametrize('path', [
    '/api/v1/admin/modules/wallet', '/api/v1/admin/wallet/chain/events',
    '/api/v1/admin/wallet/manual/operations/control',
    '/api/v1/wallet/manual/payouts/example/claim',
    '/api/v1/wallet/manual/payouts/example/txid',
    '/api/v1/wallet/manual/payouts/example/correct-candidate',
])
def test_wallet_data_requires_grant_after_admin_session(monkeypatch, path):
    calls = []
    class Tokens:
        def __init__(self, *args, **kwargs): pass
        def decode_access_token(self, token): return {'family_id': 'family'}
        def admin_session(self, token): calls.append('session')
    monkeypatch.setattr(boundary, 'TokenService', Tokens)
    monkeypatch.setattr(boundary, 'wallet_grant_service', lambda *args: SimpleNamespace(
        require=lambda **kwargs: calls.append('grant')), raising=False)
    settings = SimpleNamespace(jwt_secret=None, jwt_issuer='test', environment='test', wallet_access_grant_enabled=True)
    request = Request({'type': 'http', 'path': path, 'headers': [(b'authorization', b'Bearer token')]})
    boundary.create_admin_session_boundary(settings, None)(request)
    assert calls == ['session', 'grant']


@pytest.mark.parametrize('path', ['/api/v1/admin/overview', '/api/v1/admin/wallet/security',
    '/api/v1/admin/wallet/security/operation-password', '/api/v1/wallet/manual/access',
    '/api/v1/wallet/manual/deposit-intents'])
def test_bootstrap_and_nonwallet_routes_do_not_require_grant(path):
    assert not boundary.wallet_management_path(path)
