"""R9 A7-4: deterministic lease interleavings using the real consumer.

Only in-memory synthetic events are used. Clock advancement models elapsed
handler work, not a mocked claim implementation or a PostgreSQL lock test.
"""

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from worker import Worker


@pytest.fixture()
def queue():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = {"now": datetime(2026, 10, 11, 0, 0, tzinfo=timezone.utc)}
    consumer = OutboxConsumer(factory, now_factory=lambda: clock["now"])
    yield factory, clock, consumer
    engine.dispose()


def enqueue(factory, clock, topics):
    with factory.begin() as session:
        return [
            OutboxPublisher.enqueue(
                session,
                topic=topic,
                event_type="synthetic.lease.probe",
                aggregate_type="synthetic",
                aggregate_id=f"synthetic-{index}",
                payload={},
                now=clock["now"]
                - timedelta(seconds=100)
                + timedelta(milliseconds=index),
            )
            for index, topic in enumerate(topics)
        ]


def run_capturing_lock_loss(worker):
    try:
        worker.run_once(limit=50)
    except AppError as exc:
        # Capture the stale finalization separately from handler side effects.
        return exc.code
    return None


@pytest.mark.parametrize("slow_count,seconds_per_handler", [(1, 301), (49, 7)])
def test_unstarted_tail_is_not_preleased_then_dispatched_by_stale_worker(
    queue, slow_count, seconds_per_handler
):
    factory, clock, consumer = queue
    ids = enqueue(factory, clock, ["synthetic.slow"] * slow_count + ["synthetic.fast"])
    started = clock["now"]
    dispatches = []
    competitor_attempts = []
    trace = {}
    probed = False

    def fast_competitor(message):
        dispatches.append("worker-b")
        competitor_attempts.append(message.attempt_count)

    competitor = Worker(
        consumer=OutboxConsumer(factory, now_factory=lambda: clock["now"]),
        handlers={"synthetic.fast": fast_competitor},
        worker_id="worker-b",
        now_factory=lambda: clock["now"],
    )

    def slow(_message):
        nonlocal probed
        clock["now"] += timedelta(seconds=seconds_per_handler)
        if not probed and clock["now"] - started > timedelta(minutes=5):
            probed = True
            with factory() as session:
                tail = session.get(OutboxEvent, ids[-1])
                trace.update(
                    unstarted_status=tail.status,
                    unstarted_attempts=tail.attempt_count,
                    elapsed_seconds=(clock["now"] - started).total_seconds(),
                )
            trace["competitor_processed"] = competitor.run_once(limit=1)

    first = Worker(
        consumer=consumer,
        handlers={
            "synthetic.slow": slow,
            "synthetic.fast": lambda message: dispatches.append("worker-a"),
        },
        worker_id="worker-a",
        now_factory=lambda: clock["now"],
    )
    finalization_error = run_capturing_lock_loss(first)
    assert probed, "fixture must cross the real five-minute consumer lease"
    assert dispatches == ["worker-b"], {
        **trace,
        "tail_dispatches": dispatches,
        "competitor_attempts": competitor_attempts,
        "first_worker_finalization_error": finalization_error,
    }
    assert competitor_attempts == [
        1
    ], "unstarted work must not spend an attempt waiting in RAM"
    assert finalization_error is None


def test_active_handler_is_not_reclaimed_while_original_handler_is_still_running(queue):
    factory, clock, consumer = queue
    enqueue(factory, clock, ["synthetic.active"])
    trace = []
    competitor = Worker(
        consumer=OutboxConsumer(factory, now_factory=lambda: clock["now"]),
        handlers={"synthetic.active": lambda message: trace.append("b-enter")},
        worker_id="worker-b",
        now_factory=lambda: clock["now"],
    )

    def active(_message):
        trace.append("a-enter")
        clock["now"] += timedelta(seconds=301)
        competitor.run_once(limit=1)
        trace.append("a-exit")

    first = Worker(
        consumer=consumer,
        handlers={"synthetic.active": active},
        worker_id="worker-a",
        now_factory=lambda: clock["now"],
    )
    finalization_error = run_capturing_lock_loss(first)
    assert trace == ["a-enter", "a-exit"], {
        "handler_interleaving": trace,
        "first_worker_finalization_error": finalization_error,
    }
    assert finalization_error is None


def test_crashed_owner_is_reclaimable_only_at_lease_boundary(queue):
    """Control: recovery after a dead worker remains required behavior."""
    factory, clock, consumer = queue
    [event_id] = enqueue(factory, clock, ["synthetic.crashed"])
    assert consumer.claim_batch(worker_id="crashed", limit=1)[0].id == event_id
    clock["now"] += timedelta(seconds=299)
    assert consumer.claim_batch(worker_id="recovery", limit=1) == []
    clock["now"] += timedelta(seconds=1)
    [recovered] = consumer.claim_batch(worker_id="recovery", limit=1)
    assert recovered.id == event_id
    assert recovered.attempt_count == 2
    consumer.mark_succeeded(event_id, worker_id="recovery")
