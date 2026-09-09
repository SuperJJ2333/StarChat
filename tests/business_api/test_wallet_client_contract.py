"""Exercise the formal Flutter wallet's HTTP surface against the assembled API."""
import re

from fastapi.testclient import TestClient
import pytest

from app.core.config import Settings
from app.main import create_app


@pytest.fixture(scope='module')
def wallet_contract():
    app = create_app(Settings(_env_file=None, environment='test', database_url='sqlite://'))
    return TestClient(app), app.openapi()['paths']


# ManualWalletApi and WalletConversionCard use these session-authenticated routes.
@pytest.mark.parametrize(('method', 'path'), [
    ('get', '/wallet/config'),
    ('get', '/wallet/balances/me'),
    ('get', '/wallet/binding'),
    ('post', '/wallet/binding/challenges'),
    ('post', '/wallet/binding/confirm'),
    ('post', '/wallet/binding/address'),
    ('post', '/wallet/manual/deposit-intents'),
    ('get', '/wallet/manual/deposit-intents/current'),
    ('get', '/wallet/manual/deposit-intents/{intent_id}'),
    ('post', '/wallet/manual/payout-quotes'),
    ('post', '/wallet/manual/payouts'),
    ('get', '/wallet/manual/payouts/{order_id}'),
    ('post', '/wallet/manual/payouts/{order_id}/cancel'),
    ('post', '/wallet/conversions'),
    ('get', '/security/mfa'),
    ('post', '/security/mfa/enroll'),
    ('post', '/security/mfa/enable'),
    ('post', '/security/mfa/reauthenticate'),
    ('post', '/security/mfa/abort-pending'),
])
def test_wallet_client_routes_require_a_session_and_document_financial_keys(
    wallet_contract, method, path,
):
    client, paths = wallet_contract
    full_path = '/api/v1' + path
    operation = paths[full_path][method]
    if method == 'post' and path.startswith('/wallet/'):
        assert any(p['name'] == 'Idempotency-Key' and p['required']
                   for p in operation['parameters'])
    response = client.request(method, re.sub(r'\{[^}]+\}', 'synthetic-id', full_path),
                              json={} if method == 'post' else None)
    assert response.status_code == 401
