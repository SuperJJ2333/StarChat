"""Synthetic queue ownership, using the real Consumer and Worker."""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, event

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition,
    OutboxHandoverNotice,
    OutboxHandoverReceipt,
)
from worker import Worker

TABLES = [
    OutboxEvent.__table__,
    OutboxHandoverDisposition.__table__,
    OutboxHandoverNotice.__table__,
    OutboxHandoverReceipt.__table__,
]
OPERATIONS = [
    "renew_claim",
    "mark_claim_succeeded",
    "mark_claim_failed",
    "mark_claim_dead",
]


@pytest.fixture()
def queue():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine, tables=TABLES)
    factory = create_session_factory(engine)
    clock = [datetime(2026, 10, 11, tzinfo=timezone.utc)]
    consumer = OutboxConsumer(factory, now_factory=lambda: clock[0])
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="synthetic.claim",
            event_type="synthetic.claim",
            aggregate_type="synthetic",
            aggregate_id="synthetic",
            payload={},
            headers={"synthetic": True},
            now=clock[0],
        )
    yield factory, clock, consumer, event_id, engine
    engine.dispose()


def apply_claim(consumer, operation, event_id, clock, **token):
    extra = {}
    if operation in {"mark_claim_failed", "mark_claim_dead"}:
        extra["error"] = "synthetic error"
    if operation == "mark_claim_failed":
        extra["retry_at"] = clock[0] + timedelta(seconds=30)
    getattr(consumer, operation)(event_id, **token, **extra)


def snapshot(factory, event_id):
    with factory() as session:
        item = session.get(OutboxEvent, event_id)
        return {
            column.name: getattr(item, column.key)
            for column in OutboxEvent.__table__.columns
        }


@pytest.mark.parametrize("operation", OPERATIONS)
def test_same_worker_id_cannot_mutate_reclaimed_generation(queue, operation):
    factory, clock, consumer, event_id, _engine = queue
    [old] = consumer.claim_batch(worker_id="shared-worker", limit=1)
    clock[0] += timedelta(seconds=301)
    [new] = consumer.claim_batch(worker_id="shared-worker", limit=1)
    assert (old.attempt_count, new.attempt_count) == (1, 2)
    before = snapshot(factory, event_id)
    with pytest.raises(AppError) as failure:
        apply_claim(
            consumer,
            operation,
            event_id,
            clock,
            worker_id="shared-worker",
            attempt_count=old.attempt_count,
        )
    assert failure.value.code == "OUTBOX_LOCK_MISMATCH"
    assert snapshot(factory, event_id) == before


@pytest.mark.parametrize("operation", OPERATIONS)
@pytest.mark.parametrize("attempt", [None, 0, -1, True, "1"])
def test_new_claim_api_rejects_invalid_generation_without_mutation(
    queue, operation, attempt
):
    factory, clock, consumer, event_id, _engine = queue
    consumer.claim_batch(worker_id="worker", limit=1)
    before = snapshot(factory, event_id)
    with pytest.raises(ValueError, match="attempt_count"):
        apply_claim(
            consumer,
            operation,
            event_id,
            clock,
            worker_id="worker",
            attempt_count=attempt,
        )
    assert snapshot(factory, event_id) == before


@pytest.mark.parametrize("operation", OPERATIONS)
def test_new_claim_api_requires_generation(queue, operation):
    factory, clock, consumer, event_id, _engine = queue
    consumer.claim_batch(worker_id="worker", limit=1)
    before = snapshot(factory, event_id)
    with pytest.raises(TypeError, match="attempt_count"):
        apply_claim(consumer, operation, event_id, clock, worker_id="worker")
    assert snapshot(factory, event_id) == before


@pytest.mark.parametrize("operation", OPERATIONS)
def test_claim_api_rejects_wrong_owner_and_unknown_event(queue, operation):
    factory, clock, consumer, event_id, _engine = queue
    consumer.claim_batch(worker_id="worker", limit=1)
    before = snapshot(factory, event_id)
    for requested_id, worker in [(event_id, "other"), ("unknown", "worker")]:
        with pytest.raises(AppError) as failure:
            apply_claim(
                consumer,
                operation,
                requested_id,
                clock,
                worker_id=worker,
                attempt_count=1,
            )
        assert failure.value.code == "OUTBOX_LOCK_MISMATCH"
    assert snapshot(factory, event_id) == before


def test_renew_extends_only_current_lease_and_postpones_crash_reclaim(queue):
    factory, clock, consumer, event_id, _engine = queue
    [message] = consumer.claim_batch(worker_id="worker", limit=1)
    before = snapshot(factory, event_id)
    clock[0] += timedelta(seconds=299)
    consumer.renew_claim(
        event_id, worker_id="worker", attempt_count=message.attempt_count
    )
    after = snapshot(factory, event_id)
    assert after.pop("locked_at") == clock[0].replace(tzinfo=None)
    before.pop("locked_at")
    assert after == before
    clock[0] += timedelta(seconds=299)
    assert consumer.claim_batch(worker_id="competitor", limit=1) == []
    clock[0] += timedelta(seconds=1)
    [reclaimed] = consumer.claim_batch(worker_id="competitor", limit=1)
    assert reclaimed.attempt_count == 2


@pytest.mark.parametrize("advance_during_lock", [False, True])
def test_renew_cannot_resurrect_expired_lease(queue, advance_during_lock):
    factory, clock, consumer, event_id, engine = queue
    consumer.claim_batch(worker_id="worker", limit=1)
    before = snapshot(factory, event_id)
    deadline = clock[0] + timedelta(seconds=300)
    clock[0] = deadline - timedelta(seconds=1) if advance_during_lock else deadline

    def advance(_conn, _cursor, statement, _parameters, _context, _many):
        if statement.startswith("SELECT"):
            clock[0] = deadline

    if advance_during_lock:
        event.listen(engine, "after_cursor_execute", advance)
    try:
        with pytest.raises(AppError) as failure:
            consumer.renew_claim(event_id, worker_id="worker", attempt_count=1)
        assert failure.value.code == "OUTBOX_LEASE_EXPIRED"
    finally:
        if advance_during_lock:
            event.remove(engine, "after_cursor_execute", advance)
    assert snapshot(factory, event_id) == before


@pytest.mark.parametrize(
    "operation,status",
    [
        ("mark_claim_succeeded", "PUBLISHED"),
        ("mark_claim_failed", "FAILED"),
        ("mark_claim_dead", "DEAD"),
    ],
)
def test_expired_but_unreclaimed_generation_can_finalize_once(queue, operation, status):
    factory, clock, consumer, event_id, _engine = queue
    consumer.claim_batch(worker_id="worker", limit=1)
    clock[0] += timedelta(seconds=301)
    apply_claim(
        consumer, operation, event_id, clock, worker_id="worker", attempt_count=1
    )
    final = snapshot(factory, event_id)
    assert final["status"] == status
    assert final["attempt_count"] == 1
    assert final["locked_by"] is None and final["locked_at"] is None
    if status == "PUBLISHED":
        assert final["published_at"] == clock[0].replace(tzinfo=None)
        assert final["last_error"] is None
    else:
        assert final["last_error"] == "synthetic error"
    if status == "FAILED":
        assert final["available_at"] == (clock[0] + timedelta(seconds=30)).replace(
            tzinfo=None
        )
    for late_operation in OPERATIONS:
        with pytest.raises(AppError) as failure:
            apply_claim(
                consumer,
                late_operation,
                event_id,
                clock,
                worker_id="worker",
                attempt_count=1,
            )
        assert failure.value.code == "OUTBOX_LOCK_MISMATCH"
    assert snapshot(factory, event_id) == final


@pytest.mark.parametrize(
    "outcome,max_attempts", [("success", 10), ("failure", 10), ("failure", 1)]
)
def test_worker_uses_original_generation_for_every_completion(
    queue, outcome, max_attempts
):
    factory, clock, consumer, event_id, _engine = queue
    dispatches = []
    newer = []

    def handler(message):
        dispatches.append(message.attempt_count)
        clock[0] += timedelta(seconds=301)
        newer.extend(consumer.claim_batch(worker_id="shared-worker", limit=1))
        if outcome == "failure":
            raise RuntimeError("synthetic handler failure")

    worker = Worker(
        consumer=consumer,
        handlers={"synthetic.claim": handler},
        worker_id="shared-worker",
        now_factory=lambda: clock[0],
        max_attempts=max_attempts,
    )
    with pytest.raises(AppError) as failure:
        worker.run_once(limit=1)
    assert failure.value.code == "OUTBOX_LOCK_MISMATCH"
    assert dispatches == [1] and newer[0].attempt_count == 2
    current = snapshot(factory, event_id)
    assert current["status"] == "PROCESSING" and current["attempt_count"] == 2
    assert current["locked_by"] == "shared-worker"
    assert current["last_error"] is None and current["published_at"] is None


def test_worker_rejects_unfenced_consumer_before_any_handler_or_maintenance():
    class LegacyConsumer:
        def claim_batch(self, **kwargs):
            pytest.fail("must reject legacy consumer before claiming")

        def mark_succeeded(self, *args, **kwargs):
            pytest.fail("no legacy fallback")

    with pytest.raises(TypeError, match="claim completion"):
        Worker(consumer=LegacyConsumer(), handlers={}, worker_id="worker")
