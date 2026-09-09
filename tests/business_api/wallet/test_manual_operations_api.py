from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.core.errors import install_error_handlers
from app.modules.identity.tokens import TokenService
from app.modules.wallet.incident_models import WalletIncident
from test_manual_monitor_recovery import core, coverage, monitor  # noqa: F401


@pytest.fixture(autouse=True)
def threaded_sqlite(monkeypatch):
    import test_deposit_receipts
    from sqlalchemy import create_engine
    from sqlalchemy.pool import StaticPool
    monkeypatch.setattr(test_deposit_receipts, 'create_engine', lambda url: create_engine(url,
        connect_args={'check_same_thread':False}, poolclass=StaticPool))


@pytest.fixture
def operations(core, monitor):
    from app.api.manual_wallet_operations import create_manual_wallet_operations_router
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole
    factory = core[1]
    with factory.begin() as session:
        session.add(UserRole(id='ops-role', user_id='alice', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='fixture', assigned_at=datetime.now(timezone.utc)))
    settings = SimpleNamespace(jwt_secret='ops-test-secret-'*4, jwt_issuer='liuhetong',
        wallet_real_mode='manual_tron', wallet_manual_owner_admin_id='alice')
    app = FastAPI()
    install_error_handlers(app)
    mfa = []
    def verify(**kwargs):
        mfa.append(kwargs['proof'])
        return kwargs['proof'] == '123456'
    app.include_router(create_manual_wallet_operations_router(settings, factory,
        reviewer=monitor[0].review_once, mfa_verifier=verify, activation_monitor=monitor[0]), prefix='/api/v1/admin')
    token = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(
        user_id='alice', device_key='ops', display_name='test').access_token
    return TestClient(app), {'Authorization':'Bearer '+token, 'Idempotency-Key':'ops-key'}, settings, mfa


def test_owner_can_ack_review_resolve_without_releasing_funds(core, monitor, operations):
    client, headers, settings, mfa = operations
    source = monitor[1]
    original = source.read_reserve_cut
    source.read_reserve_cut = lambda: (_ for _ in ()).throw(ValueError('offline'))
    monitor[0].run_once()
    source.read_reserve_cut = original
    row = monitor[0].incidents.list_incidents()['items'][0]
    path = '/api/v1/admin/wallet/manual/operations/incidents/'+row['id']
    body = dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456')
    assert client.post(path+'/ack', json=body).status_code == 401
    assert client.post(path+'/ack', json=body|{'mfa_proof':'000000'}, headers=headers).status_code == 403
    ack = client.post(path+'/ack', json=body, headers=headers)
    assert ack.status_code == 200, ack.text
    review = client.post(path+'/review', json=body|{'expected_version':ack.json()['version']},
        headers=headers|{'Idempotency-Key':'review-key'})
    assert review.status_code == 200, review.text
    cleared = review.json()
    response = client.post(path+'/resolve', json=body|{'expected_version':cleared['version'],
        'clearance_digest':cleared['clearance_digest']}, headers=headers|{'Idempotency-Key':'resolve-key'})
    assert response.status_code == 200, response.text
    assert response.json()['status'] == 'RESOLVED'
    from app.modules.wallet.models import WalletControl
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused


def test_other_owner_and_unrelated_scope_cannot_use_manual_commands(core, monitor, operations):
    client, headers, settings, mfa = operations
    row = monitor[0].incidents.observe([dict(fingerprint='other:SOURCE', code='SOURCE',
        severity='P0', subject_id='global')], complete=False)[0]
    path = '/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/ack'
    body = dict(expected_version=1, reason_code='OWNER_REVIEW', mfa_proof='123456')
    assert client.post(path, json=body, headers=headers).status_code == 409
    settings.wallet_manual_owner_admin_id = 'another-owner'
    assert client.post(path, json=body, headers=headers).status_code == 403


def pending_incident(monitor):
    service, source, _ = monitor
    original = source.read_reserve_cut
    source.read_reserve_cut = lambda: (_ for _ in ()).throw(ValueError('offline'))
    service.run_once()
    source.read_reserve_cut = original
    row = service.incidents.list_incidents()['items'][0]
    return service.incidents.ack(row['id'], 'alice', 'INVESTIGATING', 'initial-ack', row['version'])


def test_incomplete_review_preserves_safe_reason_and_does_not_clear_incident(core, monitor, operations, monkeypatch):
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    monkeypatch.setattr(monitor[0], '_scan', lambda **kwargs: dict(complete=False, status='WAITING',
        codes=['MANUAL_COVERAGE_PENDING', 'SECRET_PROVIDER_VALUE']))
    response = client.post('/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/review',
        json=dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456'), headers=headers)
    assert response.status_code == 503
    error = response.json()['error']
    assert error['code'] == 'WALLET_MONITOR_UNAVAILABLE'
    assert {x['msg'] for x in error['fields'] if x['type']=='wallet.monitor.reason'} == {'MANUAL_COVERAGE_PENDING'}
    assert any(x['type']=='wallet.monitor.status' and x['msg']=='WAITING' for x in error['fields'])
    assert 'SECRET_PROVIDER_VALUE' not in response.text
    assert monitor[0].incidents.get(row['id'])['condition_active'] is True


def test_read_only_diagnostics_reports_current_evidence_without_clearing_pause(core, monitor, operations):
    from app.modules.wallet.models import WalletControl
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    path='/api/v1/admin/wallet/manual/operations/diagnostics'
    assert client.get(path).status_code == 401
    before = monitor[0].incidents.get(row['id'])
    response = client.get(path, headers=headers)
    assert response.status_code == 200, response.text
    assert response.json()['source_status'] == 'HEALTHY'
    assert response.json()['coverage_status'] == 'CURRENT'
    assert response.json()['codes'] == []
    assert 'balance' not in response.text and 'address' not in response.text
    assert monitor[0].incidents.get(row['id']) == before
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused


@pytest.mark.parametrize('case,source_status,coverage_status,reason', [
    ('offline','UNAVAILABLE','UNAVAILABLE','MANUAL_SOURCE_UNAVAILABLE'),
    ('expired','UNHEALTHY','CURRENT','MANUAL_SOURCE_UNHEALTHY'),
    ('lag','HEALTHY','WAITING','MANUAL_COVERAGE_PENDING'),
    ('gap','HEALTHY','CONFLICT','MANUAL_COVERAGE_GAP'),
])
def test_diagnostic_reasons_are_safe_and_do_not_mutate_incidents(core, monitor, operations, monkeypatch,
                                                               case, source_status, coverage_status, reason):
    from dataclasses import replace
    from app.modules.wallet.funding_scan_models import WalletFundingScanState
    client, headers, _, _ = operations
    before = monitor[0].incidents.list_incidents()
    if case == 'offline':
        monkeypatch.setattr(monitor[1], 'read_reserve_cut', lambda: (_ for _ in ()).throw(RuntimeError('PRIVATE_PROVIDER_SECRET')))
    elif case == 'expired':
        monitor[1].value = replace(monitor[1].value, fresh_until_ms=0)
    else:
        with core[1].begin() as session:
            state = session.get(WalletFundingScanState, 'global')
            if case == 'lag': state.checkpoint_ms -= 1
            else: state.source_identity = 'different'
    result = client.get('/api/v1/admin/wallet/manual/operations/diagnostics', headers=headers)
    assert result.status_code == 200
    assert result.json()['source_status'] == source_status
    assert result.json()['coverage_status'] == coverage_status
    assert result.json()['codes'] == [reason]
    assert 'PRIVATE_PROVIDER_SECRET' not in result.text
    assert monitor[0].incidents.list_incidents() == before


def test_diagnostics_labels_advancing_snapshot_as_retry_not_new_conflict(core, monitor, operations, monkeypatch):
    from dataclasses import replace
    client, headers, _, _ = operations
    cut = monitor[1].value
    reads = iter([cut, replace(cut, observation_id=cut.observation_id+1)])
    monkeypatch.setattr(monitor[1], 'read_reserve_cut', lambda: next(reads))
    result = client.get('/api/v1/admin/wallet/manual/operations/diagnostics', headers=headers)
    assert result.status_code == 200
    assert result.json()['coverage_status'] == 'WAITING'
    assert result.json()['codes'] == ['MANUAL_SOURCE_CHANGED']


@pytest.mark.parametrize('change', ['role', 'account', 'hold', 'session', 'device', 'mfa_age', 'login_age'])
@pytest.mark.parametrize('operation', ['review', 'resolve'])
def test_manual_completion_rechecks_authority_after_scan(core, monitor, operations, monkeypatch, change, operation):
    from datetime import timedelta
    from app.modules.identity.enums import AccountStatus, HoldType
    from app.modules.identity.models import User, UserRole, SecurityHold, Device, RefreshTokenFamily
    from app.modules.wallet.incident_models import WalletIncidentCommand
    import app.api.manual_wallet_operations as api
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    if operation == 'resolve':
        monitor[0].review_once()
        row = monitor[0].incidents.get(row['id'])
    moment = [datetime.now(timezone.utc)]
    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return moment[0]
    monkeypatch.setattr(api, 'datetime', Clock)
    original = monitor[1].read_reserve_cut
    def changed():
        if change == 'mfa_age':
            moment[0] += timedelta(seconds=31)
        else:
            with core[1].begin() as session:
                if change == 'role':
                    role = session.get(UserRole, 'ops-role')
                    if role is not None:
                        session.delete(role)
                elif change == 'account':
                    session.get(User, 'alice').status = AccountStatus.SUSPENDED
                elif change == 'hold':
                    if session.get(SecurityHold, 'scan-hold') is None:
                        session.add(SecurityHold(id='scan-hold', user_id='alice', hold_type=HoldType.WITHDRAWAL,
                            reason_code='RECOVERY', starts_at=moment[0]-timedelta(seconds=1),
                            ends_at=moment[0]+timedelta(hours=1), created_at=moment[0]))
                elif change == 'session':
                    session.scalar(select(RefreshTokenFamily)).revoked_at = moment[0]
                elif change == 'device':
                    session.scalar(select(Device)).revoked_at = moment[0]
                elif change == 'login_age':
                    session.scalar(select(RefreshTokenFamily)).created_at = moment[0]-timedelta(minutes=6)
        return original()
    monkeypatch.setattr(monitor[1], 'read_reserve_cut', changed)
    body = dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456')
    if operation == 'resolve':
        body['clearance_digest'] = row['clearance_digest']
    response = client.post('/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/'+operation,
        headers=headers, json=body)
    assert response.status_code in (401, 403), response.text
    current = monitor[0].incidents.get(row['id'])
    assert current['condition_active'] == row['condition_active']
    assert current['status'] == row['status'] and current['version'] == row['version']
    with core[1]() as session:
        assert session.get(WalletIncidentCommand, 'ops-key') is None


def test_manual_review_retry_replays_without_scan_and_rejects_changed_payload(core, monitor, operations, monkeypatch):
    from app.modules.wallet.incident_models import WalletIncidentCommand
    from app.modules.audit.models import AuditEvent
    from sqlalchemy import func
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    path = '/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/review'
    body = dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456')
    first = client.post(path, headers=headers, json=body)
    assert first.status_code == 200, first.text
    def offline():
        pytest.fail('committed review replay must not read provider')
    monkeypatch.setattr(monitor[1], 'read_reserve_cut', offline)
    replay = client.post(path, headers=headers, json=body)
    assert replay.status_code == 200, replay.text
    assert replay.json() == first.json()
    conflict = client.post(path, headers=headers, json=body|{'reason_code':'CHANGED_REASON'})
    assert conflict.status_code == 409
    assert conflict.json()['error']['code'] == 'WALLET_INCIDENT_IDEMPOTENCY_CONFLICT'
    with core[1]() as session:
        assert session.get(WalletIncidentCommand, 'ops-key').result == first.json()
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.action == 'wallet.manual_incident.reviewed')) == 1


def test_failed_manual_review_has_no_success_command(core, monitor, operations, monkeypatch):
    from app.modules.wallet.incident_models import WalletIncidentCommand
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    monkeypatch.setattr(monitor[1], 'read_reserve_cut', lambda: (_ for _ in ()).throw(ValueError('private provider text')))
    response = client.post('/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/review',
        headers=headers, json=dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456'))
    assert response.status_code == 503 and 'private provider text' not in response.text
    with core[1]() as session:
        assert session.get(WalletIncidentCommand, 'ops-key') is None


def test_ack_rechecks_mfa_age_after_waiting_for_incident_lock(core, monitor, operations, monkeypatch):
    from datetime import timedelta
    import app.api.manual_wallet_operations as api
    import app.modules.wallet.incidents as incidents
    from app.modules.wallet.incident_models import WalletIncidentCommand
    client, headers, _, _ = operations
    row = monitor[0].incidents.observe([dict(fingerprint='manual-reserve:SOURCE', code='SOURCE',
        severity='P0', subject_id='global')], complete=False)[0]
    moment = [datetime.now(timezone.utc)]
    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return moment[0]
    monkeypatch.setattr(api, 'datetime', Clock)
    original = incidents._lock
    def delayed(session):
        original(session)
        moment[0] += timedelta(seconds=31)
    monkeypatch.setattr(incidents, '_lock', delayed)
    response = client.post('/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/ack',
        headers=headers, json=dict(expected_version=1, reason_code='INVESTIGATING', mfa_proof='123456'))
    assert response.status_code == 403 and response.json()['error']['code'] == 'TOTP_REQUIRED'
    assert monitor[0].incidents.get(row['id'])['status'] == 'OPEN'
    with core[1]() as session:
        assert session.get(WalletIncidentCommand, 'ops-key') is None


def test_manual_review_rolls_back_clearance_if_command_record_fails(core, monitor, operations, monkeypatch):
    from app.modules.wallet.incident_models import WalletIncidentCommand
    from app.modules.wallet.incidents import WalletIncidentService
    from app.core.errors import AppError
    client, headers, _, _ = operations
    row = pending_incident(monitor)
    original = WalletIncidentService._record
    def rejected(self, session, incident, action, *args, **kwargs):
        if action == 'wallet.manual_incident.reviewed':
            raise AppError(code='REVIEW_REJECTED', message='review rejected', status_code=409)
        return original(self, session, incident, action, *args, **kwargs)
    monkeypatch.setattr(WalletIncidentService, '_record', rejected)
    response = client.post('/api/v1/admin/wallet/manual/operations/incidents/'+row['id']+'/review',
        headers=headers, json=dict(expected_version=row['version'], reason_code='OWNER_REVIEW', mfa_proof='123456'))
    assert response.status_code == 409
    current = monitor[0].incidents.get(row['id'])
    assert current['condition_active'] and current['version'] == row['version']
    with core[1]() as session:
        assert session.get(WalletIncidentCommand, 'ops-key') is None
