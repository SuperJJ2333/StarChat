from datetime import datetime, timezone
from importlib.util import find_spec
import pytest
from sqlalchemy import create_engine, select
from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher


@pytest.fixture
def legacy_alerts():
    assert find_spec('app.core.outbox_handover') is not None, 'receipt-backed outbox remediation gateway required'
    from app.core.outbox_handover import OutboxHandover
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for status in ('DEAD', 'PENDING'):
            id = OutboxPublisher.enqueue(session, topic='wallet.alert', event_type='wallet.incident.opened',
                aggregate_type='wallet_incident', aggregate_id='incident', payload=dict(incident_id='incident',
                    code='MONITOR_UNAVAILABLE', severity='P0', subject_id='global'), now=now)
            session.flush()
            session.get(OutboxEvent, id).status = status
    yield factory, OutboxHandover(factory), now
    engine.dispose()


def test_notice_reserves_originals_and_receipt_links_without_changing_status(legacy_alerts):
    factory, gateway, now = legacy_alerts
    with factory.begin() as session:
        original = gateway.capture(session, incident_ids=['incident'])
        notice = gateway.enqueue(session, preparation_id='preparation', manifest_digest='a'*64,
            expected_events=original, actor_id='owner', reason_code='HANDOVER', now=now)
    messages = OutboxConsumer(factory, wallet_handover_preparation_mode=True).claim_batch(worker_id='worker', limit=100, topics=['wallet.alert'])
    assert [message.id for message in messages] == [notice]
    assert gateway.prepare_delivery(messages[0])['alert_count'] == 2
    with factory() as session:
        assert session.scalar(select(OutboxEvent.id).where(gateway.unhealthy_predicate(now))) is not None
    gateway.record_smtp_delivery(messages[0])
    assert gateway.prepare_delivery(messages[0]) is None
    with factory() as session:
        assert gateway.capture(session, incident_ids=['incident']) == original
        assert session.scalar(select(OutboxEvent.id).where(gateway.unhealthy_predicate(now))) is None
        gateway.require_delivered(session, manifest_digest='a'*64)


def test_active_lease_and_extra_failed_alert_are_not_hidden(legacy_alerts):
    factory, gateway, now = legacy_alerts
    messages = OutboxConsumer(factory).claim_batch(worker_id='worker', limit=100, topics=['wallet.alert'])
    assert messages
    with factory.begin() as session:
        with pytest.raises(Exception, match='LEASE'):
            gateway.capture(session, incident_ids=['incident'])


def test_preparation_filter_keeps_other_topics_and_normal_mode_keeps_unhandled_legacy(legacy_alerts):
    factory, gateway, now = legacy_alerts
    with factory.begin() as session:
        other = OutboxPublisher.enqueue(session, topic='identity.email', event_type='fixture', aggregate_type='fixture',
            aggregate_id='fixture', payload={}, now=now)
    messages = OutboxConsumer(factory, wallet_handover_preparation_mode=True).claim_batch(worker_id='worker',limit=100)
    assert [event.id for event in messages] == [other]
    messages = OutboxConsumer(factory).claim_batch(worker_id='normal',limit=100,topics=['wallet.alert'])
    assert len(messages) == 1 and messages[0].event_type == 'wallet.incident.opened'


@pytest.mark.parametrize('funds,mode', [(True,'manual_tron'),(False,'disabled')])
def test_preparation_config_rejects_funds_or_wrong_mode(funds, mode):
    from app.core.config import Settings
    with pytest.raises(ValueError, match='handover preparation'):
        Settings(_env_file=None,wallet_real_mode=mode,wallet_real_funds_enabled=funds,wallet_handover_preparation_mode=True)


def test_preparation_reaper_keeps_original_wallet_alert_status(legacy_alerts):
    from datetime import timedelta
    factory, gateway, now = legacy_alerts
    consumer = OutboxConsumer(factory, wallet_handover_preparation_mode=True,
        now_factory=lambda: now + timedelta(hours=1))
    assert consumer.reap_undeliverable([]) == 0
    with factory() as session:
        assert sorted(session.scalars(select(OutboxEvent.status))) == ['DEAD', 'PENDING']
