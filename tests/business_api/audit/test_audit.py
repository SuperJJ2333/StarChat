from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine, delete, update

from app.core.database import Base, create_session_factory
from app.modules.audit.models import AuditEvent
from app.modules.audit.writer import AuditWriter


@pytest.fixture()
def audit_components():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    yield engine, factory, AuditWriter(factory, now_factory=lambda: now)
    engine.dispose()


def test_audit_writer_records_safe_metadata(audit_components) -> None:
    _, factory, writer = audit_components
    event_id = writer.record(
        actor_id="admin-1",
        subject_type="user",
        subject_id="user-1",
        action="identity.role.assigned",
        result="SUCCESS",
        reason_code="ROLE_ASSIGNMENT",
        trace_id="trace-1",
        source_ip="127.0.0.1",
        source_device_id="device-1",
        before={"role": "USER", "password": "must-not-store"},
        after={"role": "SUPPORT_AGENT", "token": "must-not-store"},
    )

    with factory() as session:
        event = session.get(AuditEvent, event_id)
        assert event.before_data == {"role": "USER", "password": "[REDACTED]"}
        assert event.after_data == {"role": "SUPPORT_AGENT", "token": "[REDACTED]"}


def test_audit_rows_reject_orm_update_and_delete(audit_components) -> None:
    _, factory, writer = audit_components
    event_id = writer.record(
        actor_id="admin-1",
        subject_type="user",
        subject_id="user-1",
        action="identity.user.suspended",
        result="SUCCESS",
        reason_code="POLICY",
        trace_id="trace-2",
    )

    with pytest.raises(ValueError, match="append-only"):
        with factory.begin() as session:
            event = session.get(AuditEvent, event_id)
            event.result = "FAILED"

    with pytest.raises(ValueError, match="append-only"):
        with factory.begin() as session:
            session.delete(session.get(AuditEvent, event_id))


def test_audit_rows_reject_bulk_update_and_delete(audit_components) -> None:
    _, factory, writer = audit_components
    writer.record(
        actor_id="admin-1",
        subject_type="system",
        subject_id="liuhetong",
        action="system.config.changed",
        result="SUCCESS",
        reason_code="CONFIG_CHANGE",
        trace_id="trace-3",
    )

    with pytest.raises(ValueError, match="append-only"):
        with factory.begin() as session:
            session.execute(update(AuditEvent).values(result="FAILED"))
    with pytest.raises(ValueError, match="append-only"):
        with factory.begin() as session:
            session.execute(delete(AuditEvent))
