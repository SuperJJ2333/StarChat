"""Opt-in local PostgreSQL evidence; isolated synthetic schema only."""

from datetime import datetime, timedelta, timezone
import os
from threading import Event, Thread
from time import monotonic, sleep
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import OperationalError, TimeoutError as PoolTimeoutError

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition, OutboxHandoverNotice, OutboxHandoverReceipt,
)
from worker import Worker
from worker import LeaseRenewalError


@pytest.fixture
def pg_active():
    url = os.environ.get("IM_WORKER_LEASE_TEST_DATABASE_URL")
    if not url:
        pytest.skip("requires explicit isolated local PostgreSQL lease test URL")
    parsed = make_url(url)
    assert parsed.host in {"127.0.0.1", "localhost"}
    assert parsed.get_backend_name() == "postgresql"
    assert (parsed.database or "").startswith("im_worker_lease_")
    engine = create_engine(url, connect_args={"connect_timeout": 3})
    schema = "active_fixture_" + uuid4().hex
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    scoped = engine.execution_options(schema_translate_map={None: schema})
    try:
        Base.metadata.create_all(scoped, tables=[
            OutboxEvent.__table__, OutboxHandoverDisposition.__table__,
            OutboxHandoverNotice.__table__, OutboxHandoverReceipt.__table__,
        ])
        factory = create_session_factory(scoped)
        with factory.begin() as session:
            event_id = OutboxPublisher.enqueue(session, topic="synthetic.active", event_type="synthetic.active",
                aggregate_type="synthetic", aggregate_id="synthetic", payload={},
                now=datetime.now(timezone.utc) - timedelta(seconds=1))
        yield url, engine, scoped, factory, event_id
    finally:
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        engine.dispose()


def test_default_claim_and_renew_use_database_clock_despite_host_skew(pg_active):
    _, _, _, factory, event_id = pg_active
    consumer = OutboxConsumer(factory)
    # Simulate a host clock far ahead; default lease decisions must share DB time.
    consumer._now_factory = lambda: datetime(2099, 1, 1, tzinfo=timezone.utc)
    with factory() as session:
        before = session.scalar(text("SELECT clock_timestamp()"))
    [message] = consumer.claim_batch(worker_id="clock", limit=1)
    assert message.id == event_id
    consumer.renew_claim(event_id, worker_id="clock", attempt_count=1)
    with factory() as session:
        locked = session.get(OutboxEvent, event_id).locked_at
        after = session.scalar(text("SELECT clock_timestamp()"))
    assert before <= locked <= after


def test_dedicated_engine_enforces_real_statement_and_pool_wait_budgets(pg_active):
    from lease_renewal import create_renewal_engine
    url, ordinary, _, _, _ = pg_active
    parsed = make_url(url).update_query_dict({"options": "-c application_name=lease-fixture"})
    engine = create_renewal_engine(parsed)
    try:
        with ordinary.connect() as connection:
            assert connection.scalar(text("SHOW statement_timeout")) == "0"
        with engine.connect() as connection:
            assert connection.scalar(text("SHOW application_name")) == "lease-fixture"
            assert connection.scalar(text("SHOW statement_timeout")) == "5s"
            assert connection.scalar(text("SHOW lock_timeout")) == "1s"
            assert connection.connection.driver_connection.info.get_parameters()["connect_timeout"] == "3"
            started = monotonic()
            with pytest.raises(PoolTimeoutError):
                engine.connect()
            assert 0.8 <= monotonic() - started < 2.5
            started = monotonic()
            with pytest.raises(OperationalError) as raised:
                connection.execute(text("SELECT pg_sleep(10)"))
            assert raised.value.orig.sqlstate == "57014"
            assert 4.5 <= monotonic() - started < 7
        with ordinary.connect() as connection:
            assert connection.scalar(text("SHOW statement_timeout")) == "0"
    finally:
        engine.dispose()


def test_postgres_blocked_handler_renews_on_independent_connection(pg_active):
    from lease_renewal import create_renewal_engine
    url, _, scoped, factory, event_id = pg_active
    engine = create_renewal_engine(url).execution_options(**scoped.get_execution_options())
    renewal_factory = create_session_factory(engine)
    clock = [datetime.now(timezone.utc)]
    consumer = OutboxConsumer(factory, now_factory=lambda: clock[0])
    renewal = OutboxConsumer(renewal_factory, now_factory=lambda: clock[0])
    entered, release = Event(), Event()
    outcomes, trace = [], []
    def handler(message):
        trace.append(message.attempt_count)
        entered.set()
        assert release.wait(10)
    worker = Worker(consumer=consumer, renewal_consumer=renewal,
        handlers={"synthetic.active": handler}, worker_id="active", renewal_interval_seconds=0.01)
    def run():
        try:
            outcomes.append(worker.run_once(limit=1))
        except Exception as exc:
            outcomes.append(exc)
    thread = Thread(target=run)
    thread.start()
    try:
        assert entered.wait(2)
        # Hold the ordinary pool connection like a synchronous handler can do.
        with factory() as handler_session:
            handler_pid = handler_session.scalar(text("SELECT pg_backend_pid()"))
            for _ in range(6):
                clock[0] += timedelta(seconds=60)
                end = monotonic() + 2
                while monotonic() < end:
                    with factory() as session:
                        if session.get(OutboxEvent, event_id).locked_at == clock[0]:
                            break
                    sleep(0.005)
                else:
                    pytest.fail("live renewal did not advance lease")
            assert consumer.claim_batch(worker_id="competitor", limit=1) == []
            with renewal_factory() as session:
                assert session.scalar(text("SELECT pg_backend_pid()")) != handler_pid
    finally:
        release.set()
        thread.join(3)
        engine.dispose()
    assert not thread.is_alive() and outcomes == [1] and trace == [1]
    with factory() as session:
        assert session.get(OutboxEvent, event_id).status == "PUBLISHED"


def test_postgres_locked_renewal_fails_closed_without_waiting_for_completion_lock(pg_active):
    from lease_renewal import create_renewal_engine
    url, _, scoped, factory, event_id = pg_active
    engine = create_renewal_engine(url).execution_options(**scoped.get_execution_options())
    renewal = OutboxConsumer(create_session_factory(engine))
    entered, release, lock_rejected = Event(), Event(), Event()
    sqlstates, outcomes = [], []
    @event.listens_for(engine, "handle_error")
    def error(context):
        sqlstates.append(context.original_exception.sqlstate)
        lock_rejected.set()
    def handler(_):
        entered.set()
        assert release.wait(4)
    worker = Worker(consumer=OutboxConsumer(factory), renewal_consumer=renewal,
        handlers={"synthetic.active": handler}, worker_id="held", renewal_interval_seconds=0.1)
    def run():
        try:
            outcomes.append(worker.run_once(limit=1))
        except Exception as exc:
            outcomes.append(exc)
    thread = Thread(target=run)
    thread.start()
    try:
        assert entered.wait(2)
        with factory.begin() as blocker:
            blocker.execute(text(f'SELECT id FROM "{scoped.get_execution_options()["schema_translate_map"][None]}".outbox_events WHERE id=:id FOR UPDATE'), {"id": event_id})
            assert lock_rejected.wait(2)
            release.set()
            thread.join(1)
            assert not thread.is_alive(), "no completion must wait on the still-held row lock"
        assert sqlstates == ["55P03"]
        assert len(outcomes) == 1 and isinstance(outcomes[0], LeaseRenewalError)
        with factory() as session:
            row = session.get(OutboxEvent, event_id)
            assert (row.status, row.attempt_count, row.locked_by) == ("PROCESSING", 1, "held")
    finally:
        release.set()
        thread.join(3)
        engine.dispose()
