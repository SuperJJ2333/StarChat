from datetime import datetime, timezone

from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.modules.audit.models import AuditEvent
from worker import Worker


def test_published_worker_entrypoint_registers_handlers_and_commits_receipt():
    import main

    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    try:
        handlers = main.build_internal_publication_handlers(factory)
        assert len(handlers) == 11
        assert "wallet" in handlers

        now = datetime(2026, 9, 28, tzinfo=timezone.utc)
        with factory.begin() as session:
            event_id = OutboxPublisher.enqueue(
                session,
                topic="wallet",
                event_type="wallet.funding_scan_discovered",
                aggregate_type="wallet",
                aggregate_id="global",
                payload={"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"},
                now=now,
            )
        worker = Worker(
            consumer=OutboxConsumer(factory, now_factory=lambda: now),
            handlers=handlers,
            worker_id="published-worker-entrypoint-test",
            now_factory=lambda: now,
        )
        assert worker.run_once() == 1
        with factory() as session:
            assert session.get(OutboxEvent, event_id).status == "PUBLISHED"
            receipts = list(
                session.scalars(
                    select(AuditEvent).where(
                        AuditEvent.action == "outbox.internal_published"
                    )
                )
            )
            assert len(receipts) == 1
            assert receipts[0].subject_id == event_id
            assert set(receipts[0].after_data) == {
                "receipt_version",
                "topic",
                "event_type",
                "envelope_sha256",
            }
    finally:
        engine.dispose()
