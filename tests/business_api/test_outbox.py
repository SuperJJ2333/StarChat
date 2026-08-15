from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, func, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher


@pytest.fixture()
def outbox():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    yield factory, OutboxConsumer(factory, now_factory=lambda: now), now
    engine.dispose()


def test_enqueue_participates_in_callers_transaction(outbox) -> None:
    factory, _, now = outbox
    with factory() as session:
        OutboxPublisher.enqueue(
            session,
            topic="ledger.events",
            event_type="caibi.transfer.created",
            aggregate_type="ledger_transaction",
            aggregate_id="tx-1",
            payload={"amount": "100.00"},
            now=now,
        )
        session.rollback()

    with factory() as session:
        assert session.scalar(select(func.count()).select_from(OutboxEvent)) == 0


def test_claim_and_mark_succeeded(outbox) -> None:
    factory, consumer, now = outbox
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="wallet.events",
            event_type="withdrawal.requested",
            aggregate_type="withdrawal",
            aggregate_id="w-1",
            payload={"asset": "USDT_TRC20"},
            now=now,
        )

    claimed = consumer.claim_batch(worker_id="worker-a", limit=10)
    assert [message.id for message in claimed] == [event_id]
    assert consumer.claim_batch(worker_id="worker-b", limit=10) == []

    consumer.mark_succeeded(event_id, worker_id="worker-a")
    with factory() as session:
        event = session.get(OutboxEvent, event_id)
        assert event is not None
        assert event.status == "PUBLISHED"
        assert event.published_at == now.replace(tzinfo=None)


def test_failed_event_is_released_for_scheduled_retry(outbox) -> None:
    factory, consumer, now = outbox
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="support.events",
            event_type="ticket.assigned",
            aggregate_type="support_ticket",
            aggregate_id="ticket-1",
            payload={},
            now=now,
        )

    consumer.claim_batch(worker_id="worker-a", limit=1)
    consumer.mark_failed(
        event_id,
        worker_id="worker-a",
        error="temporary provider failure",
        retry_at=now + timedelta(minutes=5),
    )

    assert consumer.claim_batch(worker_id="worker-a", limit=1) == []
    with factory() as session:
        event = session.get(OutboxEvent, event_id)
        assert event is not None
        assert event.status == "FAILED"
        assert event.last_error == "temporary provider failure"
        assert event.locked_by is None


def test_stale_processing_lease_is_reclaimed_after_worker_crash(outbox) -> None:
    factory, consumer, now = outbox
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="identity.matrix",
            event_type="identity.matrix.provision.requested",
            aggregate_type="user",
            aggregate_id="user-1",
            payload={"user_id": "user-1"},
            now=now,
        )

    assert [m.id for m in consumer.claim_batch(worker_id="worker-a", limit=1)] == [event_id]
    recovered = OutboxConsumer(
        factory,
        now_factory=lambda: now + timedelta(minutes=6),
        lease_timeout=timedelta(minutes=5),
    )

    messages = recovered.claim_batch(worker_id="worker-b", limit=1)

    assert [m.id for m in messages] == [event_id]
    assert messages[0].attempt_count == 2
    recovered.mark_succeeded(event_id, worker_id="worker-b")
