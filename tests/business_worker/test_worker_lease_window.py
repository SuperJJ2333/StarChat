"""R9 A7-4: deterministic lease interleavings using the real consumer.

Only in-memory synthetic events are used. Clock advancement models elapsed
handler work, not a mocked claim implementation or a PostgreSQL lock test.
"""

from datetime import datetime, timedelta, timezone
import os
from threading import Event, Thread

import pytest
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition,
    OutboxHandoverNotice,
    OutboxHandoverReceipt,
)
from worker import Worker


def create_queue_tables(engine):
    # Test collection may register other business models in the shared Base.
    # This isolated lease fixture needs only the consumer's actual query tables.
    Base.metadata.create_all(
        engine,
        tables=[
            OutboxEvent.__table__,
            OutboxHandoverDisposition.__table__,
            OutboxHandoverNotice.__table__,
            OutboxHandoverReceipt.__table__,
        ],
    )


@pytest.fixture()
def queue():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    create_queue_tables(engine)
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


def test_whole_process_pause_beyond_lease_allows_reclaim_and_rejects_late_ack(queue):
    """Instant jump gives the renewer no opportunity, like a paused process.

    This remains an at-least-once limit. Operating renewal is tested with a
    genuinely blocked handler and incremental clock in test_worker_active_lease.
    """
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
    assert trace == ["a-enter", "b-enter", "a-exit"], {
        "handler_interleaving": trace,
        "first_worker_finalization_error": finalization_error,
    }
    assert finalization_error == "OUTBOX_LOCK_MISMATCH"


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


def test_run_once_keeps_limit_topics_maintenance_and_heartbeat_contract(
    queue, monkeypatch
):
    factory, clock, consumer = queue
    ids = enqueue(factory, clock, ["synthetic.known"] * 3 + ["synthetic.unknown"])
    dispatches = []
    maintenance = []
    heartbeat = []
    reaps = []
    original_reap = consumer.reap_undeliverable

    def reap(topics, **kwargs):
        reaps.append(topics)
        return original_reap(topics, **kwargs)

    monkeypatch.setattr(consumer, "reap_undeliverable", reap)
    worker = Worker(
        consumer=consumer,
        handlers={"synthetic.known": lambda message: dispatches.append(message.id)},
        worker_id="worker-a",
        now_factory=lambda: clock["now"],
        maintenance_tasks=[lambda: maintenance.append("maintenance")],
    )
    monkeypatch.setattr(
        worker, "_touch_heartbeat", lambda: heartbeat.append("heartbeat")
    )
    assert worker.run_once(limit=2) == 2
    assert dispatches == ids[:2]
    assert maintenance == ["maintenance"]
    assert heartbeat == ["heartbeat"]
    assert reaps == [["synthetic.known"]]
    with factory() as session:
        assert session.get(OutboxEvent, ids[2]).status == "PENDING"
        assert session.get(OutboxEvent, ids[2]).attempt_count == 0
        assert session.get(OutboxEvent, ids[3]).status == "PENDING"
        assert session.get(OutboxEvent, ids[3]).attempt_count == 0


@pytest.mark.parametrize("limit", [0, -1, 50])
def test_empty_or_nonpositive_limit_still_touches_heartbeat(queue, monkeypatch, limit):
    _factory, clock, consumer = queue
    heartbeat = []
    worker = Worker(
        consumer=consumer,
        handlers={"synthetic.known": lambda message: pytest.fail("empty queue")},
        worker_id="worker-a",
        now_factory=lambda: clock["now"],
    )
    monkeypatch.setattr(
        worker, "_touch_heartbeat", lambda: heartbeat.append("heartbeat")
    )
    assert worker.run_once(limit=limit) == 0
    assert heartbeat == ["heartbeat"]


def test_postgres_two_consumers_do_not_replay_unstarted_tail():
    url = os.environ.get("IM_WORKER_LEASE_TEST_DATABASE_URL")
    if not url:
        pytest.skip("isolated native PostgreSQL lease gate requires explicit test URL")
    parsed = make_url(url)
    assert parsed.get_backend_name() == "postgresql"
    assert parsed.host in {"127.0.0.1", "localhost"}
    assert (parsed.database or "").startswith("im_worker_lease_")
    engine = create_engine(url)
    create_queue_tables(engine)
    factory = create_session_factory(engine)
    clock = {"now": datetime(2026, 10, 11, 0, 0, tzinfo=timezone.utc)}
    entered, release = Event(), Event()
    outcomes, attempts, dispatches = [], [], []
    enqueue(factory, clock, ["synthetic.slow", "synthetic.fast"])

    def slow(_message):
        entered.set()
        assert release.wait(10), "test must release its first consumer"

    first = Worker(
        consumer=OutboxConsumer(factory, now_factory=lambda: clock["now"]),
        handlers={
            "synthetic.slow": slow,
            "synthetic.fast": lambda message: dispatches.append("worker-a"),
        },
        worker_id="worker-a",
        now_factory=lambda: clock["now"],
    )

    def execute_first():
        try:
            outcomes.append(run_capturing_lock_loss(first))
        except BaseException as exc:
            outcomes.append(type(exc).__name__)

    thread = Thread(target=execute_first, name="synthetic-lease-consumer")
    thread.start()
    try:
        assert entered.wait(10), "first consumer must enter its actual handler"
        clock["now"] += timedelta(seconds=301)

        def fast(message):
            dispatches.append("worker-b")
            attempts.append(message.attempt_count)

        second = Worker(
            consumer=OutboxConsumer(factory, now_factory=lambda: clock["now"]),
            handlers={"synthetic.fast": fast},
            worker_id="worker-b",
            now_factory=lambda: clock["now"],
        )
        assert second.run_once(limit=1) == 1
    finally:
        release.set()
        thread.join(10)
        engine.dispose()
    assert not thread.is_alive()
    assert dispatches == ["worker-b"], {"dispatches": dispatches, "outcomes": outcomes}
    assert attempts == [1], "unstarted tail is a first claim, not an expired retry"
    assert outcomes == [None]
