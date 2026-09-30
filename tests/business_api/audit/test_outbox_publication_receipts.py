from uuid import uuid4
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import os
from threading import Barrier, Lock

import pytest
from sqlalchemy import create_engine, event, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import OperationalError

from app.core.database import Base, create_session_factory
from app.modules.audit.models import AuditEvent
from app.modules.audit.writer import AuditWriter


def components():
    engine = create_engine("sqlite+pysqlite:///:memory:")
    Base.metadata.create_all(engine)
    return engine, create_session_factory(engine)


def record(writer, event_id, digest="a" * 64):
    operation = getattr(writer, "record_internal_publication", None)
    assert callable(operation), (
        "public AuditWriter has no idempotent internal publication receipt"
    )
    return operation(
        event_id=event_id,
        topic="wallet",
        event_type="wallet.funding_scan_discovered",
        envelope_sha256=digest,
    )


def test_durable_receipt_retry_returns_same_uuid_and_has_no_payload_copy():
    engine, factory = components()
    writer = AuditWriter(factory)
    event_id = str(uuid4())
    first = record(writer, event_id)
    assert first == record(writer, event_id)
    with factory() as session:
        rows = list(session.scalars(select(AuditEvent)))
        assert len(rows) == 1 and rows[0].id == first
        assert rows[0].subject_id == event_id
        assert rows[0].after_data == {
            "receipt_version": 1,
            "topic": "wallet",
            "event_type": "wallet.funding_scan_discovered",
            "envelope_sha256": "a" * 64,
        }
    engine.dispose()


def test_changed_digest_has_same_receipt_identity_and_fails_closed():
    engine, factory = components()
    writer = AuditWriter(factory)
    event_id = str(uuid4())
    first = record(writer, event_id)
    with pytest.raises(ValueError, match="INTERNAL_PUBLICATION_CONFLICT"):
        record(writer, event_id, "b" * 64)
    with factory() as session:
        assert len(list(session.scalars(select(AuditEvent)))) == 1
        assert session.get(AuditEvent, first).after_data["envelope_sha256"] == "a" * 64
    engine.dispose()


def test_database_failure_is_closed_and_never_success():
    class BrokenFactory:
        @contextmanager
        def begin(self):
            raise OperationalError(
                "secret SQL", {"payload": "secret"}, Exception("secret")
            )
            yield

    with pytest.raises(RuntimeError, match="^INTERNAL_PUBLICATION_STORAGE_FAILURE$"):
        record(AuditWriter(BrokenFactory()), str(uuid4()))


@pytest.mark.parametrize(
    "field,value",
    [
        ("actor_id", str(uuid4())),
        ("action", "different"),
        ("result", "FAILED"),
        ("trace_id", "different"),
        ("reason_code", "different"),
        ("subject_type", "different"),
        ("source_ip", "127.0.0.1"),
        ("source_device_id", str(uuid4())),
        ("before_data", {"receipt_version": 0}),
    ],
)
def test_all_existing_stable_fields_must_match(field, value):
    engine, factory = components()
    writer = AuditWriter(factory)
    event_id = str(uuid4())
    first = record(writer, event_id)
    # Seed a collision in a separate isolated database, never update an audit row.
    with factory() as session:
        data = {
            c.name: getattr(session.get(AuditEvent, first), c.name)
            for c in AuditEvent.__table__.columns
        }
    data[field] = value
    other_engine, other_factory = components()
    with other_factory.begin() as session:
        session.add(AuditEvent(**data))
    with pytest.raises(ValueError, match="INTERNAL_PUBLICATION_CONFLICT"):
        record(AuditWriter(other_factory), event_id)
    engine.dispose()
    other_engine.dispose()


@pytest.mark.parametrize("version", [True, 1.0, "1"])
def test_receipt_json_stable_values_require_exact_types(version):
    engine, factory = components()
    event_id = str(uuid4())
    first = record(AuditWriter(factory), event_id)
    with factory() as session:
        data = {
            c.name: getattr(session.get(AuditEvent, first), c.name)
            for c in AuditEvent.__table__.columns
        }
    data["after_data"] = dict(data["after_data"], receipt_version=version)
    other_engine, other_factory = components()
    with other_factory.begin() as session:
        session.add(AuditEvent(**data))
    with pytest.raises(ValueError, match="INTERNAL_PUBLICATION_CONFLICT"):
        record(AuditWriter(other_factory), event_id)
    engine.dispose()
    other_engine.dispose()


def isolated_pg_engine(raw):
    url = make_url(raw)
    if (
        url.drivername != "postgresql+psycopg"
        or url.host != "127.0.0.1"
        or url.port != 54836
        or url.database != "outbox_publication_test"
        or url.username != "outbox_fixture"
        or url.query
    ):
        raise ValueError("ISOLATED_PUBLICATION_FIXTURE_REQUIRED")
    return create_engine(
        url,
        connect_args={
            "connect_timeout": 5,
            "options": "-c statement_timeout=10000 -c lock_timeout=2000",
        },
    )


@pytest.mark.parametrize(
    "url",
    [
        "postgresql+psycopg://outbox_fixture:x@production:54836/outbox_publication_test",
        "postgresql+psycopg://outbox_fixture:x@127.0.0.1:54836/production",
        "postgresql+psycopg://root:x@127.0.0.1:54836/outbox_publication_test",
        "postgresql+psycopg://outbox_fixture:x@127.0.0.1:5432/outbox_publication_test",
    ],
)
def test_pg_fixture_rejects_production_or_other_database(url):
    with pytest.raises(ValueError, match="ISOLATED_PUBLICATION_FIXTURE_REQUIRED"):
        isolated_pg_engine(url)


@pytest.fixture
def receipt_pg_engine():
    raw = os.getenv("OUTBOX_PUBLICATION_TEST_DATABASE_URL")
    if raw is None:
        pytest.skip("explicit isolated PostgreSQL fixture not configured")
    engine = isolated_pg_engine(raw)
    schema = "publication_fixture_" + uuid4().hex
    # The strict URL guard above applies before any DDL. This private synthetic
    # schema cannot collide with another fixture and is always removed.
    with engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    scoped = engine.execution_options(schema_translate_map={None: schema})
    try:
        yield scoped
    finally:
        with engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        engine.dispose()


def test_real_pg_concurrent_insert_then_lost_ack_retry_and_digest_conflict(
    receipt_pg_engine,
):
    engine = receipt_pg_engine
    AuditEvent.__table__.create(engine, checkfirst=True)
    factory = create_session_factory(engine)
    event_id = str(uuid4())
    barrier = Barrier(2)
    select_barrier = Barrier(2)
    counter_lock = Lock()
    select_count = 0
    unique_conflicts = []

    def after_select(_conn, _cursor, statement, _params, _ctx, _many):
        nonlocal select_count
        if statement.startswith("SELECT ") and "audit_events." in statement:
            with counter_lock:
                select_count += 1
                participate = select_count <= 2
            if participate:
                select_barrier.wait(timeout=5)

    def on_error(context):
        if getattr(context.original_exception, "sqlstate", None) == "23505":
            unique_conflicts.append(True)

    event.listen(engine, "after_cursor_execute", after_select)
    event.listen(engine, "handle_error", on_error)

    def concurrent():
        barrier.wait(timeout=5)
        return record(AuditWriter(factory), event_id)

    with ThreadPoolExecutor(max_workers=2) as pool:
        first, second = list(pool.map(lambda _: concurrent(), range(2)))
    event.remove(engine, "after_cursor_execute", after_select)
    event.remove(engine, "handle_error", on_error)
    assert len(unique_conflicts) == 1  # Both SELECTs finished before either INSERT.
    assert first == second
    assert record(AuditWriter(factory), event_id) == first  # ACK lost after commit.
    with pytest.raises(ValueError, match="INTERNAL_PUBLICATION_CONFLICT"):
        record(AuditWriter(factory), event_id, "b" * 64)
    with factory() as session:
        rows = list(
            session.scalars(select(AuditEvent).where(AuditEvent.subject_id == event_id))
        )
        assert len(rows) == 1 and rows[0].after_data["envelope_sha256"] == "a" * 64
