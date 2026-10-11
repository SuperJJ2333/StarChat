"""Local PostgreSQL row-lock competition; no service or financial data."""

from datetime import datetime, timedelta, timezone
import os
from threading import Event, Thread, current_thread
from time import monotonic, sleep
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import OperationalError

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition,
    OutboxHandoverNotice,
    OutboxHandoverReceipt,
)
from worker import Worker


@pytest.fixture()
def pg_queue():
    url = os.environ.get("IM_WORKER_LEASE_TEST_DATABASE_URL")
    if not url:
        pytest.skip("requires explicit isolated local PostgreSQL lease test URL")
    parsed = make_url(url)
    assert parsed.get_backend_name() == "postgresql"
    assert parsed.host in {"127.0.0.1", "localhost"}
    assert (parsed.database or "").startswith("im_worker_lease_")
    engine = create_engine(
        url,
        connect_args={
            "connect_timeout": 3,
            "options": "-c statement_timeout=5000 -c lock_timeout=2000",
        },
    )
    schema = "claim_fixture_" + uuid4().hex
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    scoped = engine.execution_options(schema_translate_map={None: schema})
    try:
        Base.metadata.create_all(
            scoped,
            tables=[
                OutboxEvent.__table__,
                OutboxHandoverDisposition.__table__,
                OutboxHandoverNotice.__table__,
                OutboxHandoverReceipt.__table__,
            ],
        )
        factory = create_session_factory(scoped)
        clock = [datetime(2026, 10, 11, tzinfo=timezone.utc)]
        with factory.begin() as session:
            event_id = OutboxPublisher.enqueue(
                session,
                topic="synthetic.claim",
                event_type="synthetic.claim",
                aggregate_type="synthetic",
                aggregate_id="synthetic",
                payload={},
                now=clock[0],
            )
        consumer = OutboxConsumer(factory, now_factory=lambda: clock[0])
        yield factory, clock, consumer, event_id, engine
    finally:
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        engine.dispose()


def complete(consumer, operation, event_id, clock, attempt=1):
    kwargs = {"worker_id": "shared-worker", "attempt_count": attempt}
    if operation != "mark_claim_succeeded":
        kwargs["error"] = "synthetic failure"
    if operation == "mark_claim_failed":
        kwargs["retry_at"] = clock[0] + timedelta(seconds=30)
    getattr(consumer, operation)(event_id, **kwargs)


def launch(call, *, name):
    outcomes = []

    def run():
        try:
            outcomes.append(call())
        except Exception as exc:
            outcomes.append(exc)

    thread = Thread(target=run, name=name)
    thread.start()
    return thread, outcomes


@pytest.mark.parametrize(
    "outcome,max_attempts", [("success", 10), ("failure", 10), ("failure", 1)]
)
def test_postgres_worker_cannot_finalize_reclaimed_same_worker_id(
    pg_queue, outcome, max_attempts
):
    factory, clock, consumer, event_id, _engine = pg_queue
    entered, release = Event(), Event()
    dispatched = []

    def handler(message):
        dispatched.append(message.attempt_count)
        entered.set()
        assert release.wait(10)
        if outcome == "failure":
            raise RuntimeError("synthetic failure")

    worker = Worker(
        consumer=consumer,
        handlers={"synthetic.claim": handler},
        worker_id="shared-worker",
        max_attempts=max_attempts,
        now_factory=lambda: clock[0],
    )
    thread, outcomes = launch(lambda: worker.run_once(limit=1), name="old-worker")
    try:
        assert entered.wait(5)
        clock[0] += timedelta(seconds=301)
        contender = OutboxConsumer(factory, now_factory=lambda: clock[0])
        [newer] = contender.claim_batch(worker_id="shared-worker", limit=1)
        assert newer.attempt_count == 2
    finally:
        release.set()
        thread.join(10)
    assert not thread.is_alive()
    assert len(outcomes) == 1 and isinstance(outcomes[0], AppError), outcomes
    assert outcomes[0].code == "OUTBOX_LOCK_MISMATCH"
    assert dispatched == [1]
    with factory() as session:
        row = session.get(OutboxEvent, event_id)
        assert row.status == "PROCESSING" and row.attempt_count == 2
        assert row.published_at is None and row.last_error is None


@pytest.mark.parametrize(
    "operation,status",
    [
        ("mark_claim_succeeded", "PUBLISHED"),
        ("mark_claim_failed", "FAILED"),
        ("mark_claim_dead", "DEAD"),
    ],
)
@pytest.mark.parametrize("winner", ["claim", "completion"])
def test_postgres_claim_completion_race_checks_generation_under_lock(
    pg_queue, operation, status, winner
):
    factory, clock, consumer, event_id, engine = pg_queue
    assert callable(
        getattr(consumer, operation, None)
    ), "generation-fenced completion interface required"
    consumer.claim_batch(worker_id="shared-worker", limit=1)
    clock[0] += timedelta(seconds=301)
    locked, release, loser_started = Event(), Event(), Event()
    loser_pid = []
    contender = OutboxConsumer(factory, now_factory=lambda: clock[0])

    def hold_winner(_conn, _cursor, statement, _parameters, _context, _many):
        if current_thread().name == "race-winner" and "FOR UPDATE" in statement:
            locked.set()
            assert release.wait(10)

    def observe_loser(_conn, _cursor, statement, _parameters, _context, _many):
        if current_thread().name == "race-loser" and "FOR UPDATE" in statement:
            loser_pid.append(_conn.connection.driver_connection.info.backend_pid)
            loser_started.set()

    event.listen(engine, "after_cursor_execute", hold_winner)
    event.listen(engine, "before_cursor_execute", observe_loser)

    def claim():
        return contender.claim_batch(worker_id="shared-worker", limit=1)

    def finish():
        return complete(consumer, operation, event_id, clock)

    first_call, second_call = (claim, finish) if winner == "claim" else (finish, claim)
    first, first_outcomes = launch(first_call, name="race-winner")
    second = None
    try:
        assert locked.wait(5), first_outcomes
        second, second_outcomes = launch(second_call, name="race-loser")
        assert loser_started.wait(5)
        if winner == "claim":
            # Prove the old completion is already blocked by the uncommitted
            # newer claim, rather than merely scheduling it after that commit.
            deadline = monotonic() + 1
            while monotonic() < deadline:
                with engine.connect() as connection:
                    waiting = connection.scalar(
                        text(
                            "SELECT wait_event_type FROM pg_stat_activity WHERE pid = :pid"
                        ),
                        {"pid": loser_pid[0]},
                    )
                if waiting == "Lock":
                    break
                sleep(0.005)
            else:
                pytest.fail("old completion never waited on the newer claim's row lock")
        else:
            second.join(5)
            assert (
                not second.is_alive()
            ), "claim must SKIP LOCKED, not wait for completion"
            assert second_outcomes == [[]]
    finally:
        release.set()
        first.join(10)
        if second is not None:
            second.join(10)
        event.remove(engine, "after_cursor_execute", hold_winner)
        event.remove(engine, "before_cursor_execute", observe_loser)
    assert not first.is_alive() and second is not None and not second.is_alive()
    if winner == "claim":
        assert first_outcomes[0][0].attempt_count == 2, first_outcomes
        assert isinstance(second_outcomes[0], AppError), second_outcomes
        assert second_outcomes[0].code == "OUTBOX_LOCK_MISMATCH"
    else:
        assert first_outcomes == [None]
    with factory() as session:
        row = session.get(OutboxEvent, event_id)
        assert row.status == ("PROCESSING" if winner == "claim" else status)
        assert row.attempt_count == (2 if winner == "claim" else 1)


def test_postgres_renew_fails_nowait_without_mutating_locked_claim(pg_queue):
    factory, clock, consumer, event_id, _engine = pg_queue
    assert callable(
        getattr(consumer, "renew_claim", None)
    ), "fenced renewal interface required"
    consumer.claim_batch(worker_id="shared-worker", limit=1)
    started = clock[0]
    clock[0] += timedelta(seconds=60)
    with factory.begin() as blocker:
        blocker.scalar(
            select(OutboxEvent).where(OutboxEvent.id == event_id).with_for_update()
        )
        with pytest.raises(OperationalError) as failure:
            consumer.renew_claim(event_id, worker_id="shared-worker", attempt_count=1)
        assert (
            failure.value.orig.sqlstate == "55P03"
        )  # lock_not_available, not statement timeout
    with factory() as session:
        row = session.get(OutboxEvent, event_id)
        assert (
            row.locked_at == started
            and row.attempt_count == 1
            and row.status == "PROCESSING"
        )
    consumer.renew_claim(event_id, worker_id="shared-worker", attempt_count=1)
    with factory() as session:
        assert session.get(OutboxEvent, event_id).locked_at == clock[0]
