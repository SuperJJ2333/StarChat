from datetime import datetime, timezone
from pathlib import Path
import sys

from sqlalchemy import create_engine

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher

WORKER_APP = Path(__file__).parents[2] / "services" / "business-worker" / "app"
sys.path.insert(0, str(WORKER_APP))

from worker import Worker  # noqa: E402


def _components(handler):
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    consumer = OutboxConsumer(factory, now_factory=lambda: now)
    worker = Worker(
        consumer=consumer,
        handlers={"ledger.events": handler},
        worker_id="test-worker",
        now_factory=lambda: now,
    )
    return engine, factory, now, worker


def test_worker_dispatches_event_and_marks_success() -> None:
    handled = []
    engine, factory, now, worker = _components(handled.append)
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="ledger.events",
            event_type="caibi.transfer.created",
            aggregate_type="ledger_transaction",
            aggregate_id="tx-1",
            payload={"amount": "10.00"},
            now=now,
        )

    assert worker.run_once(limit=10) == 1
    assert [message.id for message in handled] == [event_id]
    with factory() as session:
        assert session.get(OutboxEvent, event_id).status == "PUBLISHED"
    engine.dispose()


def test_worker_failure_keeps_event_for_retry() -> None:
    def fail(_message):
        raise RuntimeError("handler failed")

    engine, factory, now, worker = _components(fail)
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(
            session,
            topic="ledger.events",
            event_type="caibi.transfer.created",
            aggregate_type="ledger_transaction",
            aggregate_id="tx-2",
            payload={},
            now=now,
        )

    assert worker.run_once(limit=10) == 1
    with factory() as session:
        event = session.get(OutboxEvent, event_id)
        assert event is not None
        assert event.status == "FAILED"
        assert event.attempt_count == 1
        assert event.last_error == "handler failed"
    engine.dispose()

def test_worker_runs_maintenance_before_outbox_poll():
    calls = []
    engine, factory, now, _worker = _components(calls.append)
    consumer = OutboxConsumer(factory, now_factory=lambda: now)
    worker = Worker(consumer=consumer, handlers={}, worker_id="test-worker", now_factory=lambda: now, maintenance_tasks=[lambda: calls.append("maintenance")])
    assert worker.run_once(limit=10) == 0
    assert calls == ["maintenance"]
    engine.dispose()


def test_worker_registers_identity_email_verification_handler() -> None:
    from main import build_identity_handlers

    handlers = build_identity_handlers(
        session_factory=object(),
        verification_secret="test-email-verification-secret",
        public_base_url="https://example.test",
        email_sender=object(),
    )

    assert set(handlers) == {"identity.email"}


def test_worker_registers_matrix_provisioning_handler() -> None:
    class Gateway:
        def ensure_user(self, localpart, password):
            raise AssertionError("handler registration must not call Synapse")

    from main import build_identity_handlers

    handlers = build_identity_handlers(
        session_factory=object(),
        verification_secret="test-email-verification-secret",
        public_base_url="https://example.test",
        email_sender=object(),
        matrix_gateway=Gateway(),
        matrix_provision_secret="test-matrix-provision-secret",
    )

    assert set(handlers) == {"identity.email", "identity.matrix"}
