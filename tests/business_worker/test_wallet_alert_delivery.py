from datetime import datetime, timedelta, timezone

import pytest

from sqlalchemy import create_engine, func, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent
from app.modules.wallet.incidents import SandboxWalletAlertHandler, WalletIncidentService
from app.modules.wallet.incident_models import WalletAlertReceipt
from worker import Worker


def test_receipt_survives_ack_loss_and_retry_is_idempotent(monkeypatch):
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    WalletIncidentService(factory, now_factory=lambda: clock[0]).observe([
        dict(fingerprint='FIXTURE:global', code='FIXTURE', severity='P0', subject_id='global')])
    consumer = OutboxConsumer(factory, now_factory=lambda: clock[0])
    original = consumer.mark_succeeded
    attempts = []
    def lost_ack(id, *, worker_id):
        attempts.append(id)
        if len(attempts) == 1:
            raise RuntimeError('SANDBOX_ACK_LOSS')
        original(id, worker_id=worker_id)
    monkeypatch.setattr(consumer, 'mark_succeeded', lost_ack)
    worker = Worker(consumer=consumer, handlers={'wallet.alert': SandboxWalletAlertHandler(factory)},
        worker_id='fixture', now_factory=lambda: clock[0])
    with pytest.raises(RuntimeError, match='SANDBOX_ACK_LOSS'):
        worker.run_once()
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 1
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert event.status == 'PROCESSING' and event.attempt_count == 1
    # A process crash after durable receipt leaves a lease; a fresh worker reclaims it.
    clock[0] += timedelta(seconds=301)
    worker = Worker(consumer=OutboxConsumer(factory, now_factory=lambda: clock[0]),
        handlers={'wallet.alert': SandboxWalletAlertHandler(factory)},
        worker_id='restarted-fixture', now_factory=lambda: clock[0])
    worker.run_once()
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 1
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert event.status == 'PUBLISHED' and event.attempt_count == 2
        assert session.scalar(select(WalletAlertReceipt)).transport == 'SANDBOX'
    engine.dispose()


def test_delivery_failure_reaches_dead_letter_without_false_receipt():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    WalletIncidentService(factory, now_factory=lambda: clock[0]).observe([
        dict(fingerprint='FIXTURE:global', code='FIXTURE', severity='P0', subject_id='global')])
    def failed(event):
        raise RuntimeError('SANDBOX_DELIVERY_FAILED')
    worker = Worker(consumer=OutboxConsumer(factory, now_factory=lambda: clock[0]),
        handlers={'wallet.alert': failed}, worker_id='fixture', now_factory=lambda: clock[0], max_attempts=2)
    worker.run_once()
    clock[0] += timedelta(seconds=31)
    worker.run_once()
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletAlertReceipt)) == 0
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert event.status == 'DEAD' and event.attempt_count == 2
    engine.dispose()
