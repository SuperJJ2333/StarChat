import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from unittest.mock import patch

import pytest
from sqlalchemy import create_engine, event as sql_event, func, select, text
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxMessage
from app.modules.audit.models import AuditEvent


@pytest.fixture(params=['sqlite'] + (['postgres'] if os.getenv('INCIDENT_PG_URL') else []))
def factory(request):
    from app.modules.wallet import incident_models  # noqa: F401
    admin = None
    if request.param == 'postgres':
        schema = 'incidents_' + uuid4().hex
        admin = create_engine(os.environ['INCIDENT_PG_URL'])
        with admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        engine = create_engine(os.environ['INCIDENT_PG_URL'], connect_args={'options': f'-csearch_path={schema}'})
    else:
        engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool)
    Base.metadata.create_all(engine)
    yield create_session_factory(engine)
    engine.dispose()
    if admin is not None:
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


SIGNAL = dict(fingerprint='withdrawal:abc:unknown', code='WITHDRAWAL_UNKNOWN', severity='P0', subject_id='abc')
NOW = datetime(2026, 9, 6, tzinfo=timezone.utc)


def service(factory, at=NOW):
    from app.modules.wallet.incidents import WalletIncidentService
    return WalletIncidentService(factory, now_factory=lambda: at)


def test_open_dedup_clear_review_recurrence_and_original_replay(factory):
    svc = service(factory)
    opened = svc.observe([SIGNAL])[0]
    assert opened['status'] == 'OPEN' and opened['generation'] == 1
    seen = svc.observe([SIGNAL])[0]
    assert seen['id'] == opened['id']
    ack = svc.ack(opened['id'], 'owner', 'INVESTIGATE', 'ack-one', seen['version'])
    assert ack['acknowledged_by'] == 'owner' and ack['status'] == 'ACKNOWLEDGED'
    with pytest.raises(AppError):
        svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'bad-active', ack['version'], 'f'*64)
    svc.observe([])
    cleared = svc.get(opened['id'])
    assert not cleared['condition_active'] and len(cleared['clearance_digest']) == 64
    with pytest.raises(AppError):
        svc.resolve(opened['id'], 'owner', 'REVIEWED', 'same-actor', cleared['version'], cleared['clearance_digest'])
    with pytest.raises(AppError):
        svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'bad-digest', cleared['version'], 'a'*64)
    closed = svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'resolve-one', cleared['version'], cleared['clearance_digest'])
    assert closed['status'] == 'RESOLVED'
    assert svc.ack(opened['id'], 'owner', 'INVESTIGATE', 'ack-one', seen['version']) == ack
    assert svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'resolve-one', cleared['version'], cleared['clearance_digest']) == closed
    reopened = service(factory, NOW + timedelta(minutes=1)).observe([SIGNAL])[0]
    assert reopened['generation'] == 2 and reopened['status'] == 'OPEN'
    assert reopened['acknowledged_by'] is None and reopened['clearance_digest'] is None
    with pytest.raises(AppError):
        svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'old-clearance', reopened['version'], cleared['clearance_digest'])
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent)) >= 5
        alerts = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')).all()
        assert len(alerts) == 2
        assert all(set(a.payload) == {'incident_id', 'subject_id', 'code', 'severity'} for a in alerts)


def test_version_payload_binding_and_no_ack_resolution(factory):
    svc = service(factory)
    opened = svc.observe([SIGNAL])[0]
    svc.observe([])
    inactive = svc.get(opened['id'])
    with pytest.raises(AppError):
        svc.resolve(opened['id'], 'reviewer', 'REVIEWED', 'no-ack', inactive['version'], inactive['clearance_digest'])
    with pytest.raises(AppError) as stale:
        svc.ack(opened['id'], 'owner', 'INVESTIGATE', 'stale', opened['version'])
    assert stale.value.status_code == 409
    ack = svc.ack(opened['id'], 'owner', 'INVESTIGATE', 'one', inactive['version'])
    for actor, reason, version in [('other', 'INVESTIGATE', inactive['version']), ('owner', 'OTHER', inactive['version']), ('owner', 'INVESTIGATE', ack['version'])]:
        with pytest.raises(AppError) as collision:
            svc.ack(opened['id'], actor, reason, 'one', version)
        assert collision.value.status_code == 409


def test_p0_escalation_boundaries_restart_and_ack_stop(factory):
    opened = service(factory).observe([SIGNAL])[0]
    assert service(factory, NOW + timedelta(seconds=299)).escalate() == []
    assert len(service(factory, NOW + timedelta(seconds=300)).escalate()) == 1
    assert service(factory, NOW + timedelta(seconds=599)).escalate() == []
    assert len(service(factory, NOW + timedelta(seconds=600)).escalate()) == 1
    svc = service(factory, NOW + timedelta(seconds=600))
    row = svc.get(opened['id'])
    svc.ack(row['id'], 'owner', 'INVESTIGATE', 'ack', row['version'])
    assert service(factory, NOW + timedelta(hours=1)).escalate() == []
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')) == 3


def test_sandbox_receipts_are_durable_and_deduplicate(factory):
    from app.modules.wallet.incidents import SandboxWalletAlertHandler
    from app.modules.wallet.incident_models import WalletAlertReceipt
    service(factory).observe([SIGNAL])
    with factory() as session:
        row = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        event = OutboxMessage(row.id, row.topic, row.event_type, row.aggregate_type, row.aggregate_id, row.payload, {}, 1)
    SandboxWalletAlertHandler(factory)(event)
    SandboxWalletAlertHandler(factory)(event)
    with factory() as session:
        receipts = session.scalars(select(WalletAlertReceipt)).all()
        assert len(receipts) == 1 and receipts[0].transport == 'SANDBOX'
        assert receipts[0].payload == event.payload
    with pytest.raises(AppError):
        SandboxWalletAlertHandler(factory)(replace(event, payload=dict(event.payload, code='OTHER_CODE')))
    with pytest.raises(AppError):
        SandboxWalletAlertHandler(factory)(replace(event, payload=dict(event.payload, secret='unsafe')))


def test_sandbox_receipt_transaction_failure_is_retryable(factory):
    from app.modules.wallet.incidents import SandboxWalletAlertHandler
    from app.modules.wallet.incident_models import WalletAlertReceipt
    service(factory).observe([SIGNAL])
    with factory() as session:
        row = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        event = OutboxMessage(row.id, row.topic, row.event_type, row.aggregate_type, row.aggregate_id, row.payload, {}, 1)
    def fail_insert(connection, cursor, statement, parameters, context, executemany):
        if statement.startswith('INSERT INTO wallet_alert_receipts'):
            raise RuntimeError('transient receipt persistence failure')
    engine = factory.kw['bind']
    sql_event.listen(engine, 'before_cursor_execute', fail_insert)
    try:
        with pytest.raises(RuntimeError):
            SandboxWalletAlertHandler(factory)(event)
    finally:
        sql_event.remove(engine, 'before_cursor_execute', fail_insert)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 0
    SandboxWalletAlertHandler(factory)(event)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 1


def test_listing_keyset_and_invalid_signal_is_atomic(factory):
    svc = service(factory)
    svc.observe([SIGNAL, dict(SIGNAL, fingerprint='withdrawal:def:unknown', subject_id='def')])
    page = svc.list_incidents(limit=1)
    second = svc.list_incidents(limit=1, cursor=page['next_cursor'])
    assert len(page['items']) == len(second['items']) == 1
    assert page['items'][0]['id'] != second['items'][0]['id']
    with pytest.raises(AppError):
        svc.observe([dict(SIGNAL, severity='BAD')])
    assert all(i['condition_active'] for i in svc.list_incidents()['items'])


def test_audit_outbox_failure_rolls_back_state_and_command_receipt(factory):
    from app.modules.wallet.incident_models import WalletIncidentCommand
    svc = service(factory)
    with patch('app.modules.wallet.incidents.OutboxPublisher.enqueue', side_effect=RuntimeError('unavailable')):
        with pytest.raises(RuntimeError):
            svc.observe([SIGNAL])
    assert svc.list_incidents()['items'] == []
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent)) == 0
    row = svc.observe([SIGNAL])[0]
    with patch('app.modules.wallet.incidents.OutboxPublisher.enqueue', side_effect=RuntimeError('unavailable')):
        with pytest.raises(RuntimeError):
            svc.ack(row['id'], 'owner', 'INVESTIGATE', 'rollback', row['version'])
    assert svc.get(row['id'])['status'] == 'OPEN'
    with factory() as session:
        assert session.get(WalletIncidentCommand, 'rollback') is None
    assert svc.ack(row['id'], 'owner', 'INVESTIGATE', 'rollback', row['version'])['status'] == 'ACKNOWLEDGED'


def test_recurrence_before_review_discards_previous_ack_and_clearance(factory):
    svc = service(factory)
    row = svc.observe([SIGNAL])[0]
    svc.ack(row['id'], 'owner', 'INVESTIGATE', 'ack-old', row['version'])
    svc.observe([])
    cleared = svc.get(row['id'])
    row = svc.observe([SIGNAL])[0]
    assert row['generation'] == 2 and row['acknowledged_by'] is None
    assert row['clearance_digest'] is None and row['status'] == 'OPEN'
    with pytest.raises(AppError):
        svc.resolve(row['id'], 'reviewer', 'REVIEWED', 'old', row['version'], cleared['clearance_digest'])


def test_p1_does_not_escalate_and_contradictory_fingerprint_rolls_back(factory):
    svc = service(factory)
    row = svc.observe([dict(SIGNAL, severity='P1')])[0]
    assert service(factory, NOW + timedelta(hours=1)).escalate() == []
    with pytest.raises(AppError):
        svc.observe([dict(SIGNAL, subject_id='another')])
    assert svc.get(row['id']) == row


def test_partial_failed_scan_opens_monitor_failure_without_clearing_conditions(factory):
    svc = service(factory)
    active = svc.observe([SIGNAL])[0]
    failure = dict(fingerprint='monitor:unavailable', code='MONITOR_UNAVAILABLE', severity='P0', subject_id='global')
    failed = svc.observe([failure], complete=False)[0]
    assert svc.get(active['id'])['condition_active'] is True
    assert svc.get(active['id'])['clearance_digest'] is None
    assert failed['condition_active'] is True
    svc.observe([], complete=True)
    assert all(not row['condition_active'] and row['clearance_digest'] for row in svc.list_incidents()['items'])


def test_postgres_concurrent_open_ack_and_receipt(factory):
    if factory.kw['bind'].dialect.name != 'postgresql':
        pytest.skip('PostgreSQL serialization verification')
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: service(factory).observe([SIGNAL])[0], range(4)))
    assert len({r['id'] for r in results}) == 1
    row = service(factory).get(results[0]['id'])
    def ack(_):
        try:
            return service(factory).ack(row['id'], 'owner', 'INVESTIGATE', 'concurrent', row['version'])
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(ack, range(4)))
    assert all(r == results[0] for r in results) and isinstance(results[0], dict)
    from app.modules.wallet.incidents import SandboxWalletAlertHandler
    from app.modules.wallet.incident_models import WalletAlertReceipt
    with factory() as session:
        row = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        event = OutboxMessage(row.id, row.topic, row.event_type, row.aggregate_type, row.aggregate_id, row.payload, {}, 1)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: SandboxWalletAlertHandler(factory)(event), range(4)))
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 1
