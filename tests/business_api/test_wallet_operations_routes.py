from datetime import datetime, timedelta, timezone

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, update
from sqlalchemy.pool import StaticPool

from app.api.admin import create_admin_router
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole, RefreshTokenFamily
from app.modules.identity.tokens import TokenService
from app.modules.wallet.incidents import WalletIncidentService


@pytest.fixture
def ops():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment='test', jwt_secret='test-'*8)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    now = datetime.now(timezone.utc)
    headers = {}
    for id in ['finance', 'reviewer', 'ordinary']:
        with factory.begin() as session:
            session.add(User(id=id, username=id, username_normalized=id, email=id+'@example.invalid',
                email_normalized=id+'@example.invalid', password_hash='unused-fixture',
                status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
            if id != 'ordinary':
                session.add(UserRole(id=id, user_id=id, role_code=RoleCode.FINANCE_SUPPORT, assigned_by='fixture', assigned_at=now))
        pair = tokens.issue_pair(user_id=id, device_key=id, display_name='fixture')
        headers[id] = {'Authorization': 'Bearer '+pair.access_token, 'Idempotency-Key': id+'-command'}
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_admin_router(settings, factory), prefix='/api/v1')
    yield TestClient(app), headers, factory, settings
    engine.dispose()


def test_close_auth_replay_and_read(ops):
    client, headers, factory, settings = ops
    path = '/api/v1/admin/wallet/reports/close'
    day = (datetime.now(timezone.utc)+timedelta(hours=8)-timedelta(days=1)).date().isoformat()
    body = dict(day=day, reason_code='DAILY_CLOSE')
    assert client.post(path, json=body).status_code == 401
    assert client.post(path, json=body, headers=headers['ordinary']).status_code == 403
    response = client.post(path, json=body, headers=headers['finance'])
    assert response.status_code == 200, response.text
    assert response.headers['cache-control'] == 'no-store'
    assert client.post(path, json=body, headers=headers['finance']).json() == response.json()
    result = client.get('/api/v1/admin/wallet/reports/closed/'+response.json()['id'], headers=headers['finance'])
    assert result.json() == response.json()


def test_commands_require_recent_server_login_and_failclosed_production(ops):
    client, headers, factory, settings = ops
    path = '/api/v1/admin/wallet/reports/close'
    body = dict(day='2026-09-01', reason_code='DAILY_CLOSE')
    settings.environment = 'production'
    assert client.post(path, json=body, headers=headers['finance']).status_code == 503
    settings.environment = 'test'
    with factory.begin() as session:
        session.execute(update(RefreshTokenFamily).values(created_at=datetime.now(timezone.utc)-timedelta(minutes=6)))
    response = client.post(path, json=body, headers=headers['finance'])
    assert response.status_code == 403
    assert response.json()['error']['code'] == 'RECENT_LOGIN_REQUIRED'


def test_incident_two_person_workflow_never_clears_active_condition(ops):
    client, headers, factory, settings = ops
    svc = WalletIncidentService(factory)
    row = svc.observe([dict(fingerprint='MANUAL:global', code='MANUAL', severity='P0', subject_id='global')])[0]
    path = '/api/v1/admin/wallet/incidents/'+row['id']
    assert client.get(path, headers=headers['ordinary']).status_code == 403
    body = dict(expected_version=row['version'], reason_code='INVESTIGATING')
    response = client.post(path+'/ack', json=body, headers=headers['finance'])
    assert response.status_code == 200, response.text
    ack = response.json()
    response = client.post(path+'/resolve', json=dict(expected_version=ack['version'],
        reason_code='REVIEWED', clearance_digest='0'*64), headers=headers['reviewer'])
    assert response.status_code == 409
    assert svc.get(row['id'])['status'] == 'ACKNOWLEDGED'
    assert client.get('/api/v1/admin/wallet/monitor/status', headers=headers['finance']).status_code == 200


def test_command_contract_rejects_missing_key_and_extra_fields(ops):
    client, headers, factory, settings = ops
    auth = {'Authorization': headers['finance']['Authorization']}
    path = '/api/v1/admin/wallet/reports/close'
    assert client.post(path, json=dict(day='2026-09-01', reason_code='DAILY_CLOSE'), headers=auth).status_code == 422
    response = client.post(path, json=dict(day='2026-09-01', reason_code='DAILY_CLOSE', actor_id='reviewer'), headers=headers['finance'])
    assert response.status_code == 422
    assert response.headers['cache-control'] == 'no-store'


def test_resolve_replay_does_not_rescan_or_depend_on_provider(ops, monkeypatch):
    from app.modules.wallet.monitoring import WalletMonitoringService
    client, headers, factory, settings = ops
    svc = WalletIncidentService(factory)
    row = svc.observe([dict(fingerprint='MANUAL:global', code='MANUAL', severity='P0', subject_id='global')])[0]
    svc.ack(row['id'], 'finance', 'INVESTIGATING', 'ack', row['version'])
    svc.observe([])
    cleared = svc.get(row['id'])
    body = dict(expected_version=cleared['version'], reason_code='REVIEWED', clearance_digest=cleared['clearance_digest'])
    result = svc.resolve(row['id'], actor_id='reviewer', idempotency_key='reviewer-command', **body)
    def fail(self):
        raise AssertionError('replay must not scan or mutate incidents')
    monkeypatch.setattr(WalletMonitoringService, 'run_once', fail)
    response = client.post('/api/v1/admin/wallet/incidents/'+row['id']+'/resolve', json=body, headers=headers['reviewer'])
    assert response.status_code == 200, response.text
    assert response.json() == result
