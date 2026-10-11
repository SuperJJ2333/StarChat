"""Independent synthetic boundaries; imports frozen production modules."""
from datetime import datetime, timedelta, timezone
import os
from threading import Event, Thread, get_ident
from time import sleep

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.core.outbox_handover_models import (
    OutboxHandoverDisposition, OutboxHandoverNotice, OutboxHandoverReceipt,
)
from lease_renewal import create_renewal_engine
from worker import LeaseRenewalError, Worker


def test_inflight_renewal_crossing_policy_deadline_settles_but_never_acks(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{(tmp_path / 'independent.db').as_posix()}")
    Base.metadata.create_all(engine, tables=[OutboxEvent.__table__,
        OutboxHandoverDisposition.__table__, OutboxHandoverNotice.__table__,
        OutboxHandoverReceipt.__table__])
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    consumer = OutboxConsumer(factory, now_factory=lambda: now)
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(session, topic='review.active', event_type='review.active',
            aggregate_type='synthetic', aggregate_id='one', payload={}, now=now)
        tail = OutboxPublisher.enqueue(session, topic='review.active', event_type='review.active',
            aggregate_type='synthetic', aggregate_id='two', payload={}, now=now + timedelta(seconds=1))
    in_io, release_io, handler_done, io_done = Event(), Event(), Event(), Event()
    ticks, tokens, outcomes, handler_threads = [0.0], [], [], []

    class HeldRenewal:
        def renew_claim(self, supplied, **token):
            tokens.append((supplied, token))
            in_io.set()
            assert release_io.wait(3)
            consumer.renew_claim(supplied, **token)
            io_done.set()

    def handler(_):
        handler_threads.append(get_ident())
        assert in_io.wait(2)
        handler_done.set()

    worker = Worker(consumer=consumer, renewal_consumer=HeldRenewal(),
        handlers={'review.active': handler}, worker_id='independent',
        renewal_interval_seconds=0.01, renewal_join_seconds=2,
        monotonic_factory=lambda: ticks[0])

    def run():
        try:
            outcomes.append(worker.run_once(limit=2))
        except BaseException as error:
            outcomes.append(error)

    thread = Thread(target=run)
    thread.start()
    try:
        assert handler_done.wait(2)
        ticks[0] = 900.0
        assert thread.is_alive(), 'completion must still await true renewal I/O'
        release_io.set()
        thread.join(3)
        assert not thread.is_alive() and io_done.is_set()
        assert len(outcomes) == 1 and isinstance(outcomes[0], LeaseRenewalError)
        assert str(outcomes[0]) == 'renewal_limit'
        assert handler_threads == [thread.ident]
        with factory() as session:
            first, second = session.get(OutboxEvent, event_id), session.get(OutboxEvent, tail)
            assert (first.status, first.attempt_count, first.locked_by) == ('PROCESSING', 1, 'independent')
            assert (second.status, second.attempt_count) == ('PENDING', 0)
        with pytest.raises(LeaseRenewalError):
            worker.run_once(limit=1)
        sleep(0.04)
        assert tokens == [(event_id, {'worker_id': 'independent', 'attempt_count': 1})]
    finally:
        release_io.set()
        thread.join(3)
        engine.dispose()


def test_database_policy_cannot_be_overridden_by_url_timeout_options():
    raw = os.environ['IM_WORKER_LEASE_TEST_DATABASE_URL']
    url = make_url(raw)
    assert url.host == '127.0.0.1' and url.port == 55483
    assert url.database == 'im_worker_lease_independent_utf8'
    url = url.update_query_dict({'connect_timeout': '120', 'options':
        '-c application_name=independent-review -c statement_timeout=120000 -c lock_timeout=120000'})
    engine = create_renewal_engine(url)
    try:
        with engine.connect() as connection:
            assert connection.scalar(text('SHOW application_name')) == 'independent-review'
            assert connection.scalar(text('SHOW statement_timeout')) == '5s'
            assert connection.scalar(text('SHOW lock_timeout')) == '1s'
            assert connection.scalar(text('SHOW idle_in_transaction_session_timeout')) == '5s'
            params = connection.connection.driver_connection.info.get_parameters()
            assert params['connect_timeout'] == '3'
            assert params['tcp_user_timeout'] == '5000'
    finally:
        engine.dispose()
