from datetime import datetime, timezone

from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxConsumer, OutboxEvent, OutboxPublisher
from app.modules.audit.models import AuditEvent
from worker import Worker
from threading import Event
from types import SimpleNamespace
from unittest.mock import MagicMock

from sqlalchemy import event


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


def test_actual_main_uses_dedicated_renewal_and_keeps_publication_receipt(tmp_path, monkeypatch):
    """Import/call the shipped entrypoint, replacing only external/maintenance I/O."""
    import main
    from app.integrations.tron import diagnostics

    database_url = f"sqlite+pysqlite:///{(tmp_path / 'entry.db').as_posix()}"
    engine = create_engine(database_url)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    with factory.begin() as session:
        event_id = OutboxPublisher.enqueue(session, topic="wallet", event_type="wallet.funding_scan_discovered",
            aggregate_type="wallet", aggregate_id="global",
            payload={"id": "global", "reason_code": "FUNDING_SCAN_DISCOVERED"})
    engine.dispose()
    settings = SimpleNamespace(database_url=database_url, environment="development", red_packet_max_total=100,
        email_verification_secret=None, password_reset_secret=None, matrix_provision_secret=None,
        avatar_storage_root="unused")
    monkeypatch.setattr(main, "Settings", lambda: settings)
    for name in ("RedPacketService", "LedgerService", "ChatTransferService", "RedPacketExpiryTask",
                 "RedPacketCommissionSweepTask", "ChatTransferExpiryTask", "RechargeRegistrationTask",
                 "MomentsModerationTask", "email_sender_from_environment", "SynapseMatrixAdminGateway",
                 "LocalPrivateAvatarReader", "build_blob_backend", "signal"):
        monkeypatch.setattr(main, name, MagicMock())
    monkeypatch.setattr(main, "build_wallet_tasks", lambda *_: (lambda: None, lambda: None, {}))
    monkeypatch.setattr(main, "build_identity_handlers", lambda **_: {})
    monkeypatch.setattr(diagnostics, "configure", lambda *_: None)
    monkeypatch.setattr(diagnostics, "emit", lambda *_, **__: None)
    monkeypatch.setenv("WORKER_HEARTBEAT_PATH", str(tmp_path / "heartbeat"))
    renewed = Event()
    engines = []
    # Observe actual SQL from the factory used by main, not a fake renew method.
    from lease_renewal import create_renewal_engine
    def instrumented_factory(url):
        renewal_engine = create_renewal_engine(url)
        engines.append(renewal_engine)
        @event.listens_for(renewal_engine, "after_cursor_execute")
        def after_execute(_conn, _cursor, statement, *_):
            if statement.startswith("UPDATE outbox_events"):
                renewed.set()
        return renewal_engine
    monkeypatch.setattr(main, "create_renewal_engine", instrumented_factory, raising=False)
    class EntrypointWorker(Worker):
        def __init__(self, **kwargs):
            assert "renewal_consumer" in kwargs, "default main must wire independent renewal"
            assert kwargs["consumer"] is not kwargs["renewal_consumer"]
            assert len(kwargs["handlers"]) == 11 and "wallet" in kwargs["handlers"]
            original = kwargs["handlers"]["wallet"]
            def held_handler(message):
                original(message)
                assert renewed.wait(2), "actual entrypoint renewal must execute while handler is held"
            kwargs["handlers"]["wallet"] = held_handler
            super().__init__(**kwargs, renewal_interval_seconds=0.01)
        def run_forever(self, **kwargs):
            assert self.run_once(limit=1) == 1
    monkeypatch.setattr(main, "Worker", EntrypointWorker)
    main.main()
    assert renewed.is_set() and len(engines) == 1
    engine = create_engine(database_url)
    try:
        with create_session_factory(engine)() as session:
            assert session.get(OutboxEvent, event_id).status == "PUBLISHED"
            receipts = list(session.scalars(select(AuditEvent).where(AuditEvent.subject_id == event_id)))
            assert len(receipts) == 1 and receipts[0].action == "outbox.internal_published"
    finally:
        engine.dispose()
