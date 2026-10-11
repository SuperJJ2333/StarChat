"""Real queue/blocked-handler lifecycle tests; only synthetic local rows."""

from datetime import datetime, timedelta, timezone
from threading import Event, Thread, get_ident
from time import monotonic, sleep

import pytest
from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.errors import AppError
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition, OutboxHandoverNotice, OutboxHandoverReceipt,
)
import worker as worker_module
from worker import Worker


@pytest.fixture
def active_queue(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{(tmp_path / 'queue.db').as_posix()}")
    Base.metadata.create_all(engine, tables=[
        OutboxEvent.__table__, OutboxHandoverDisposition.__table__,
        OutboxHandoverNotice.__table__, OutboxHandoverReceipt.__table__,
    ])
    factory = create_session_factory(engine)
    clock = [datetime(2026, 10, 11, tzinfo=timezone.utc)]
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session, topic="synthetic.active", event_type="synthetic.active",
            aggregate_type="synthetic", aggregate_id="synthetic", payload={}, now=clock[0],
        )
    yield factory, clock, OutboxConsumer(factory, now_factory=lambda: clock[0]), event_id
    engine.dispose()


def launch(call):
    outcomes = []
    def run():
        try:
            outcomes.append(call())
        except BaseException as exc:
            outcomes.append(exc)
    thread = Thread(target=run)
    thread.start()
    return thread, outcomes


def wait_for(predicate, timeout=2):
    end = monotonic() + timeout
    while monotonic() < end:
        if predicate():
            return True
        sleep(0.005)
    return False


def row(factory, event_id):
    with factory() as session:
        event = session.get(OutboxEvent, event_id)
        locked = event.locked_at
        if locked is not None and locked.tzinfo is None:
            locked = locked.replace(tzinfo=timezone.utc)
        return event.status, event.attempt_count, event.locked_by, locked


def test_blocked_handler_crossing_five_minutes_retains_single_dispatch(active_queue, monkeypatch):
    factory, clock, consumer, event_id = active_queue
    # Shorten only scheduling cadence; the real consumer lease stays 300 seconds.
    monkeypatch.setattr(worker_module, "DEFAULT_RENEWAL_INTERVAL_SECONDS", 0.01, raising=False)
    entered, release = Event(), Event()
    dispatches, handler_threads = [], []
    def handler(message):
        dispatches.append(("a", message.attempt_count))
        handler_threads.append(get_ident())
        entered.set()
        assert release.wait(10)
    worker = Worker(consumer=consumer, handlers={"synthetic.active": handler}, worker_id="a")
    thread, outcomes = launch(lambda: worker.run_once(limit=1))
    try:
        assert entered.wait(2)
        for _ in range(6):
            clock[0] += timedelta(seconds=60)
            wait_for(lambda: row(factory, event_id)[3] == clock[0], timeout=0.3)
        competitor = Worker(
            consumer=OutboxConsumer(factory, now_factory=lambda: clock[0]),
            handlers={"synthetic.active": lambda message: dispatches.append(("b", message.attempt_count))},
            worker_id="b",
        )
        competitor.run_once(limit=1)
    finally:
        release.set()
        thread.join(3)
    assert not thread.is_alive()
    assert dispatches == [("a", 1)], (dispatches, outcomes)
    assert outcomes == [1]
    assert handler_threads == [thread.ident], "handler must remain on its calling thread"
    assert row(factory, event_id)[:3] == ("PUBLISHED", 1, None)


@pytest.mark.parametrize("failure", ["lost", "expired", "database", "committed_unknown"])
def test_renewal_fault_blocks_late_completion_and_all_future_claims(active_queue, failure, caplog):
    factory, clock, consumer, event_id = active_queue
    attempted, release = Event(), Event()
    calls = []
    class FaultingRenewal:
        def renew_claim(self, supplied_id, *, worker_id, attempt_count):
            calls.append((supplied_id, worker_id, attempt_count))
            try:
                if failure == "committed_unknown":
                    consumer.renew_claim(supplied_id, worker_id=worker_id, attempt_count=attempt_count)
                if failure in {"lost", "expired"}:
                    raise AppError(code="OUTBOX_LOCK_MISMATCH" if failure == "lost" else "OUTBOX_LEASE_EXPIRED",
                                   message="synthetic", status_code=409)
                raise RuntimeError("sensitive-db-exception-must-not-be-logged")
            finally:
                attempted.set()
    def handler(_):
        assert attempted.wait(2)
        assert release.wait(2)
    worker = Worker(consumer=consumer, renewal_consumer=FaultingRenewal(),
                    handlers={"synthetic.active": handler}, worker_id="a", renewal_interval_seconds=0.01)
    thread, outcomes = launch(lambda: worker.run_once(limit=2))
    try:
        assert attempted.wait(2)
    finally:
        release.set()
        thread.join(3)
    assert not thread.is_alive()
    assert len(outcomes) == 1 and isinstance(outcomes[0], worker_module.LeaseRenewalError)
    assert row(factory, event_id)[:3] == ("PROCESSING", 1, "a")
    with pytest.raises(worker_module.LeaseRenewalError):
        worker.run_once()
    assert calls == [(event_id, "a", 1)]
    assert "sensitive-db-exception" not in caplog.text


def test_same_worker_reset_generation_is_not_renewed_or_completed(active_queue):
    factory, clock, consumer, event_id = active_queue
    entered, release = Event(), Event()
    def handler(_):
        entered.set()
        assert release.wait(3)
    worker = Worker(consumer=consumer, handlers={"synthetic.active": handler}, worker_id="same",
                    renewal_interval_seconds=0.05)
    thread, outcomes = launch(lambda: worker.run_once(limit=1))
    try:
        assert entered.wait(2)
        clock[0] += timedelta(seconds=301)
        [newer] = consumer.claim_batch(worker_id="same", limit=1)
        assert newer.attempt_count == 2
        # Let the original renewer observe the newer generation before returning.
        sleep(0.15)
    finally:
        release.set()
        thread.join(3)
    assert isinstance(outcomes[0], worker_module.LeaseRenewalError)
    assert row(factory, event_id)[:3] == ("PROCESSING", 2, "same")


def test_stop_keeps_current_lease_but_does_not_claim_next_event(active_queue):
    factory, clock, consumer, event_id = active_queue
    with factory.begin() as session:
        tail = OutboxPublisher.enqueue(session, topic="synthetic.active", event_type="synthetic.active",
            aggregate_type="synthetic", aggregate_id="tail", payload={}, now=clock[0] + timedelta(seconds=1))
    entered, release, stop = Event(), Event(), Event()
    calls = []
    def handler(message):
        calls.append(message.id)
        entered.set()
        assert release.wait(3)
    worker = Worker(consumer=consumer, handlers={"synthetic.active": handler}, worker_id="a",
                    renewal_interval_seconds=0.01)
    thread, outcomes = launch(lambda: worker.run_forever(stop_event=stop))
    try:
        assert entered.wait(2)
        stop.set()
        clock[0] += timedelta(seconds=100)
        assert wait_for(lambda: row(factory, event_id)[3] == clock[0])
    finally:
        release.set()
        thread.join(3)
    assert outcomes == [None] and not thread.is_alive()
    assert calls == [event_id]
    assert row(factory, event_id)[0] == "PUBLISHED"
    assert row(factory, tail)[:3] == ("PENDING", 0, None)


def test_cap_stops_renewal_even_during_shutdown_and_rejects_late_handler(active_queue):
    factory, clock, consumer, event_id = active_queue
    entered, release, renewed, stop = Event(), Event(), Event(), Event()
    ticks, calls = [0.0], []
    class RecordingRenewal:
        def renew_claim(self, supplied_id, **kwargs):
            consumer.renew_claim(supplied_id, **kwargs)
            calls.append(supplied_id)
            renewed.set()
    def handler(_):
        entered.set()
        assert release.wait(3)
    worker = Worker(consumer=consumer, renewal_consumer=RecordingRenewal(),
        handlers={"synthetic.active": handler}, worker_id="a", renewal_interval_seconds=0.01,
        monotonic_factory=lambda: ticks[0])
    thread, outcomes = launch(lambda: worker.run_forever(stop_event=stop))
    try:
        assert entered.wait(2) and renewed.wait(2)
        stop.set()
        ticks[0] = 900.0
        sleep(0.05)
        count = len(calls)
        sleep(0.04)
        assert len(calls) == count
    finally:
        release.set()
        thread.join(3)
    assert isinstance(outcomes[0], worker_module.LeaseRenewalError)
    assert str(outcomes[0]) == "renewal_limit"
    assert row(factory, event_id)[0] == "PROCESSING"
    clock[0] += timedelta(seconds=300)
    assert consumer.claim_batch(worker_id="recovery", limit=1)[0].attempt_count == 2


@pytest.mark.parametrize("outcome,max_attempts,expected", [
    ("success", 10, "PUBLISHED"), ("error", 10, "FAILED"), ("error", 1, "DEAD"),
])
def test_completion_waits_for_inflight_renewal_and_then_retires_it(active_queue, outcome, max_attempts, expected):
    factory, clock, consumer, event_id = active_queue
    in_renew, release_renew, handler_returned = Event(), Event(), Event()
    calls = []
    class HeldRenewal:
        def renew_claim(self, supplied_id, **kwargs):
            calls.append(supplied_id)
            in_renew.set()
            assert release_renew.wait(3)
            consumer.renew_claim(supplied_id, **kwargs)
    def handler(_):
        assert in_renew.wait(2)
        handler_returned.set()
        if outcome == "error":
            raise RuntimeError("synthetic handler failure")
    worker = Worker(consumer=consumer, renewal_consumer=HeldRenewal(),
        handlers={"synthetic.active": handler}, worker_id="a", renewal_interval_seconds=0.01,
        max_attempts=max_attempts)
    thread, outcomes = launch(lambda: worker.run_once(limit=1))
    try:
        assert handler_returned.wait(2)
        assert row(factory, event_id)[0] == "PROCESSING"
        assert thread.is_alive()
    finally:
        release_renew.set()
        thread.join(3)
    assert outcomes == [1]
    assert row(factory, event_id)[0] == expected
    sleep(0.03)
    assert calls == [event_id]


def test_unsettled_renewal_has_bounded_join_and_cannot_restart(active_queue):
    factory, clock, consumer, event_id = active_queue
    in_renew, release, settled = Event(), Event(), Event()
    calls = []
    class StuckRenewal:
        def renew_claim(self, supplied_id, **kwargs):
            calls.append(supplied_id)
            in_renew.set()
            assert release.wait(3)
            consumer.renew_claim(supplied_id, **kwargs)
            settled.set()
    worker = Worker(consumer=consumer, renewal_consumer=StuckRenewal(),
        handlers={"synthetic.active": lambda _: in_renew.wait(2)}, worker_id="a",
        renewal_interval_seconds=0.01, renewal_join_seconds=0.03)
    started = monotonic()
    try:
        with pytest.raises(worker_module.LeaseRenewalError, match="renewal_unsettled"):
            worker.run_once(limit=1)
        assert monotonic() - started < 1
        with pytest.raises(worker_module.LeaseRenewalError):
            worker.run_once(limit=1)
        assert row(factory, event_id)[0] == "PROCESSING"
    finally:
        release.set()
        assert settled.wait(2)
    sleep(0.04)
    assert calls == [event_id]


def test_missing_renewal_contract_fails_before_claim():
    class CompletionOnly:
        mark_claim_succeeded = mark_claim_failed = mark_claim_dead = lambda *args, **kwargs: None
        def claim_batch(self, **kwargs):
            pytest.fail("invalid consumer must not claim")
    with pytest.raises(TypeError, match="renew_claim"):
        Worker(consumer=CompletionOnly(), handlers={}, worker_id="a")


def test_aborted_renewal_thread_is_unknown_not_success(active_queue):
    factory, _, consumer, event_id = active_queue
    attempted = Event()
    class Aborted(BaseException):
        pass
    class AbortedRenewal:
        def renew_claim(self, *_, **__):
            attempted.set()
            raise Aborted()
    worker = Worker(consumer=consumer, renewal_consumer=AbortedRenewal(),
        handlers={"synthetic.active": lambda _: attempted.wait(2)}, worker_id="a",
        renewal_interval_seconds=0.01)
    with pytest.raises(worker_module.LeaseRenewalError, match="renewal_unknown"):
        worker.run_once(limit=1)
    assert row(factory, event_id)[0] == "PROCESSING"


@pytest.mark.parametrize("options", [
    {"renewal_interval_seconds": float("inf"), "renewal_max_seconds": float("inf")},
    {"renewal_max_seconds": float("inf")}, {"renewal_join_seconds": float("inf")},
    {"renewal_join_seconds": float("nan")},
])
def test_nonfinite_lifecycle_budget_cannot_enable_unbounded_renewal(active_queue, options):
    _, _, consumer, _ = active_queue
    with pytest.raises(ValueError):
        Worker(consumer=consumer, handlers={}, worker_id="a", **options)
