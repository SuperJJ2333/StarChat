from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from fastapi import FastAPI, Request as FastAPIRequest
from fastapi.testclient import TestClient
from pydantic import SecretStr
from starlette.requests import Request

from app.api import admin_session_boundary as boundary
from app.core.errors import AppError, install_error_handlers
from tests.business_api.identity.test_wallet_access_grant import grant_context  # noqa: F401
from tests.business_api.tron.test_admin_query import watch_db  # noqa: F401


@pytest.mark.parametrize('path', [
    '/api/v1/admin/modules/wallet', '/api/v1/admin/wallet/chain/events',
    '/api/v1/admin/wallet/manual/operations/control',
    '/api/v1/wallet/manual/payouts/example/claim',
    '/api/v1/wallet/manual/payouts/example/adjust-rate',
    '/api/v1/wallet/manual/payouts/example/txid',
    '/api/v1/wallet/manual/payouts/example/correct-candidate',
])
def test_wallet_write_paths_require_grant_after_admin_session(monkeypatch, path):
    calls = []
    class Tokens:
        def __init__(self, *args, **kwargs): pass
        def decode_access_token(self, token): return {'family_id': 'family'}
        def admin_session(self, token): calls.append('session')
    monkeypatch.setattr(boundary, 'TokenService', Tokens)
    monkeypatch.setattr(boundary, 'wallet_grant_service', lambda *args: SimpleNamespace(
        require=lambda **kwargs: calls.append('grant')), raising=False)
    settings = SimpleNamespace(jwt_secret=None, jwt_issuer='test', environment='test', wallet_access_grant_enabled=True)
    request = Request({'type': 'http', 'method': 'POST', 'path': path,
        'headers': [(b'authorization', b'Bearer token')]})
    boundary.create_admin_session_boundary(settings, None)(request)
    assert calls == ['session', 'grant']


WALLET_READ_CASES = [
    ('/api/v1/admin/modules/wallet', '/admin/modules/{module}'),
    ('/api/v1/admin/wallet/reports/daily?day=2026-09-27', '/admin/wallet/reports/daily'),
    ('/api/v1/admin/wallet/reports/closed/closed', '/wallet/reports/closed/{id}'),
    ('/api/v1/admin/wallet/incidents', '/wallet/incidents'),
    ('/api/v1/admin/wallet/incidents/incident', '/wallet/incidents/{id}'),
    ('/api/v1/admin/wallet/monitor/status', '/wallet/monitor/status'),
    ('/api/v1/admin/wallet/chain/summary', '/wallet/chain/summary'),
    ('/api/v1/admin/wallet/chain/transactions', '/wallet/chain/transactions'),
    ('/api/v1/admin/wallet/chain/transactions/' + 'a'*64 + '/0', '/wallet/chain/transactions/{txid}/{log_index}'),
    ('/api/v1/admin/wallet/manual/payouts', '/wallet/manual/payouts'),
    ('/api/v1/admin/wallet/manual/payouts/order', '/wallet/manual/payouts/{order_id}'),
    ('/api/v1/admin/wallet/manual/operations/control', '/wallet/manual/operations/control'),
    ('/api/v1/admin/wallet/manual/operations/diagnostics', '/wallet/manual/operations/diagnostics'),
    ('/api/v1/admin/wallet/manual/handover/id', '/wallet/manual/handover/{id}'),
    ('/api/v1/admin/wallet/manual/deposit-repairs/candidates?txid=' + 'a'*64 + '&log_index=0',
        '/wallet/manual/deposit-repairs/candidates'),
    ('/api/v1/admin/wallet/manual/deposit-repairs/operation', '/wallet/manual/deposit-repairs/{operation_id}'),
    ('/api/v1/admin/wallet/manual/manual-deposit-cases/context?txid=' + 'a'*64 + '&log_index=0',
        '/wallet/manual/manual-deposit-cases/context'),
    ('/api/v1/admin/wallet/manual/manual-deposit-cases/operations/operation',
        '/wallet/manual/manual-deposit-cases/operations/{operation_id}'),
    ('/api/v1/admin/wallet/manual/manual-deposit-cases/case', '/wallet/manual/manual-deposit-cases/{case_id}'),
    ('/api/v1/admin/wallet/manual/payout-reconciliations/operation',
        '/wallet/manual/payout-reconciliations/{operation_id}'),
    ('/api/v1/admin/wallet/manual/owner-transfers/' + 'a'*64,
        '/wallet/manual/owner-transfers/{txid}'),
]


@pytest.mark.parametrize('path, route_path', WALLET_READ_CASES)
def test_wallet_read_allowlist_requires_real_route_and_only_reads(monkeypatch, path, route_path):
    calls = []
    class Tokens:
        def __init__(self, *args, **kwargs): pass
        def decode_access_token(self, token): return {'family_id': 'family'}
        def admin_session(self, token): calls.append('session')
    monkeypatch.setattr(boundary, 'TokenService', Tokens)
    monkeypatch.setattr(boundary, 'wallet_grant_service', lambda *args: SimpleNamespace(
        require=lambda **kwargs: calls.append('grant'),
        require_read=lambda **kwargs: calls.append('read')))
    settings = SimpleNamespace(jwt_secret=None, jwt_issuer='test', environment='test', wallet_access_grant_enabled=True)
    path = path.split('?', 1)[0]
    request = Request({'type': 'http', 'method': 'GET', 'path': path,
        'route': SimpleNamespace(path=route_path), 'headers': [(b'authorization', b'Bearer token')]})
    boundary.create_admin_session_boundary(settings, None)(request)
    assert calls == ['session', 'read']
    assert request.state.wallet_read_token == 'token'
    for method, template in [('POST', route_path), ('GET', '/wallet/future'), ('GET', None)]:
        calls.clear()
        scope = {'type': 'http', 'method': method, 'path': path,
            'headers': [(b'authorization', b'Bearer token')]}
        if template is not None:
            scope['route'] = SimpleNamespace(path=template)
        boundary.create_admin_session_boundary(settings, None)(Request(scope))
        assert calls == ['session', 'grant']


def test_wallet_read_response_guard_blocks_payload_after_owner_revocation(monkeypatch):
    calls = []

    class Tokens:
        def __init__(self, *args, **kwargs): pass
        def decode_access_token(self, token):
            return {'sub': 'owner', 'family_id': 'family'}
        def admin_session(self, token):
            calls.append('session')
            return {'sub': 'owner', 'family_id': 'family'}

    class Grants:
        def require_read(self, *, claims):
            calls.append('read')
            raise AppError(code='PERMISSION_DENIED', message='钱包负责人权限已撤销', status_code=403)

    monkeypatch.setattr(boundary, 'TokenService', Tokens)
    monkeypatch.setattr(boundary, 'wallet_grant_service', lambda *args: Grants())
    settings = SimpleNamespace(jwt_secret='test-secret', jwt_issuer='test', environment='test')
    app = FastAPI()
    install_error_handlers(app)
    boundary.install_wallet_read_response_guard(app, settings, None)

    @app.get('/sensitive')
    def sensitive(request: FastAPIRequest):
        request.state.wallet_read_token = 'token'
        return {'secret': 'must-never-leak'}

    response = TestClient(app, raise_server_exceptions=False).get('/sensitive')
    assert response.status_code == 403
    assert 'must-never-leak' not in response.text
    assert response.json()['error']['code'] == 'PERMISSION_DENIED'
    assert calls == ['session', 'read']


def test_wallet_read_route_templates_match_real_app(grant_context, watch_db, monkeypatch):
    import jwt
    from coincurve import PrivateKey
    from fastapi.testclient import TestClient
    from app.core.config import Settings
    from app.core.database import Base
    from app.main import create_app
    from app.integrations.tron.finality import SolidHead, TransactionEvidence, TransferEvidence
    from app.integrations.tron.message_signature import address_from_public_key
    from app.integrations.tron.reader import USDT_CONTRACT
    from app.modules.wallet.closing import WalletClosingService
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.incidents import WalletIncidentService
    from app.modules.wallet.incident_reports import WalletIncidentReports
    from app.modules.identity.models import UserRole
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder, ManualPayoutQuote
    from app.modules.wallet.receipt_models import DepositReceipt
    from app.modules.wallet.receipts import DepositReceiptService
    from app.modules.wallet.runtime import ManualWalletRuntime

    _, factory, _, claims, _ = grant_context
    Base.metadata.create_all(factory.kw['bind'])
    now = datetime.now(timezone.utc)
    source, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    transfer = TransferEvidence('a'*64, 0, 102, 'b'*64, int(now.timestamp()*1000), source, official, 10000000)
    proof = TransactionEvidence('a'*64, 102, 'b'*64, transfer.timestamp_ms,
        SolidHead(103, 'c'*64, int(now.timestamp()*1000), now), (transfer,), now)
    adapter = SimpleNamespace(transaction_evidence=lambda txid: proof if txid == proof.txid else None, close=lambda: None)
    receipts = DepositReceiptService(factory, finality_adapter=adapter,
        official_config=OfficialFundingConfig(official, 'test-v1'),
        activation_baseline_time=now-timedelta(days=1), activation_baseline_height=100,
        clock=lambda: datetime.now(timezone.utc))
    runtime = ManualWalletRuntime(None, None, receipts, SimpleNamespace(), adapter, True)
    monkeypatch.setattr('app.main.create_manual_wallet_runtime', lambda *args: runtime)
    settings = Settings(_env_file=None, environment='test', database_url='sqlite://',
        jwt_secret='test-wallet-boundary-secret-at-least-32-bytes',
        wallet_access_grant_enabled=True, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', tron_observer_database_path=str(watch_db))
    settings.wallet_official_address = SecretStr(official)
    settings.wallet_official_config_version = 'test-v1'
    settings.wallet_funding_baseline_at = now-timedelta(days=1)
    settings.wallet_funding_baseline_height = 100
    app = create_app(settings, session_factory=factory)
    settings.wallet_real_mode = 'manual_tron'
    close_day = now.astimezone(ZoneInfo('Asia/Hong_Kong')).date()-timedelta(days=1)
    closed = WalletClosingService(factory).close(close_day, 'owner', 'FIXTURE_CLOSE', 'fixture-close')
    incident = WalletIncidentService(factory).observe([dict(fingerprint='fixture:owner-read',
        code='FIXTURE_INCIDENT', severity='P1', subject_id='global')])[0]
    payout_snapshot = dict(binding_id='binding', binding_version=1, target_address=source,
        official_address=official, official_config_version='test-v1', owner_admin_id='owner',
        policy_version='test-v1', approval_policy='OWNER_MANUAL_V1', finality_policy='fixture',
        network='tron-mainnet', contract=USDT_CONTRACT, amount='10.000000', fee='0.000000',
        hold='10.000000', receive='10.000000', minimum='10.000000', max_per='1000.000000',
        user_24h='1000.000000', global_24h='1000.000000', safety_epoch=0,
        created_at=now.isoformat(), expires_at=(now+timedelta(minutes=5)).isoformat())
    with factory.begin() as session:
        session.add(ManualPayoutQuote(id='quote', user_id='owner', amount=Decimal('10'),
            snapshot=payout_snapshot, digest='d'*64, created_at=now, expires_at=now+timedelta(minutes=5)))
        session.add(ManualPayoutOrder(id='order', quote_id='quote', user_id='owner', amount=Decimal('10'),
            digest='d'*64, status='REQUESTED', created_at=now, updated_at=now))
        session.add(DepositReceipt(id='receipt', network='tron-mainnet', contract=USDT_CONTRACT,
            txid=proof.txid, log_index=0, source_address=source, official_address=official,
            official_config_version='test-v1', amount_units='10000000', amount=Decimal('10'),
            block_number=102, block_id='b'*64, block_time=now, evidence_policy=proof.policy,
            evidence_source=proof.source_id, observed_at=now, facts_digest='e'*64,
            status='REVIEW', reason_code='UNMATCHED_INTENT', pending_obligation=True))
    observed = []
    @app.middleware('http')
    async def record_route(request, call_next):
        try:
            return await call_next(request)
        finally:
            observed.append(getattr(request.scope.get('route'), 'path', None))
    client = TestClient(app, raise_server_exceptions=False)
    headers = {'Authorization':'Bearer ' + jwt.encode(claims | {'iss':settings.jwt_issuer},
        settings.jwt_secret, algorithm='HS256')}
    fixture_paths = {
        '/api/v1/admin/wallet/reports/closed/closed': f'/api/v1/admin/wallet/reports/closed/{closed["id"]}',
        '/api/v1/admin/wallet/incidents/incident': f'/api/v1/admin/wallet/incidents/{incident["id"]}',
        '/api/v1/admin/wallet/chain/transactions/' + 'a'*64 + '/0':
            '/api/v1/admin/wallet/chain/transactions/' + '1'*64 + '/0',
    }
    expected_status = {
        '/wallet/manual/handover/{id}': 404,
        '/wallet/manual/deposit-repairs/{operation_id}': 404,
        '/wallet/manual/manual-deposit-cases/operations/{operation_id}': 404,
        '/wallet/manual/manual-deposit-cases/{case_id}': 404,
        '/wallet/manual/payout-reconciliations/{operation_id}': 404,
    }
    for path, template in WALLET_READ_CASES:
        path = fixture_paths.get(path, path)
        response = client.get(path, headers=headers)
        assert observed[-1] == template, path
        assert response.status_code == expected_status.get(template, 200), (path, response.text)
        if response.status_code == 200:
            assert response.headers['cache-control'] == 'no-store', path

    # The owner may be revoked while a slower DB or chain read is running.
    # Its assembled payload must be replaced before any bytes leave the API.
    original_list = WalletIncidentReports.list
    def revoke_during_read(service, **kwargs):
        payload = original_list(service, **kwargs)
        with factory.begin() as session:
            session.delete(session.get(UserRole, 'role'))
        return payload
    monkeypatch.setattr(WalletIncidentReports, 'list', revoke_during_read)
    revoked = client.get('/api/v1/admin/wallet/incidents', headers=headers)
    assert revoked.status_code == 401, revoked.text
    assert revoked.json()['error']['code'] == 'ADMIN_SESSION_REPLACED'
    assert 'fixture:owner-read' not in revoked.text


@pytest.mark.parametrize('path', ['/api/v1/admin/overview', '/api/v1/admin/wallet/security',
    '/api/v1/admin/wallet/security/operation-password', '/api/v1/wallet/manual/access',
    '/api/v1/wallet/manual/deposit-intents'])
def test_bootstrap_and_nonwallet_routes_do_not_require_grant(path):
    assert not boundary.wallet_management_path(path)
