import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.modules.audit.models import AuditEvent
from app.modules.settings.models import AppSetting
from app.modules.settings.service import (
    APP_LATEST_VERSION_KEY,
    RED_PACKET_MAX_TOTAL_KEY,
    SettingService,
)


@pytest.fixture()
def settings_components():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    yield SettingService(factory), factory
    engine.dispose()


def test_get_returns_default_when_key_missing(settings_components) -> None:
    service, _ = settings_components
    assert service.get("missing") is None
    assert service.get("missing", default="fallback") == "fallback"


def test_set_creates_row_and_audit_event(settings_components) -> None:
    service, factory = settings_components
    row = service.set(
        RED_PACKET_MAX_TOTAL_KEY, "5000.00", actor_id="admin-1", trace_id="trace-1"
    )
    assert row.key == RED_PACKET_MAX_TOTAL_KEY
    assert row.value == "5000.00"
    assert row.updated_by == "admin-1"

    with factory() as session:
        stored = session.get(AppSetting, RED_PACKET_MAX_TOTAL_KEY)
        assert stored is not None and stored.value == "5000.00"
        event = session.scalar(
            select(AuditEvent).where(AuditEvent.subject_id == RED_PACKET_MAX_TOTAL_KEY)
        )
    assert event is not None
    assert event.action == "settings.update"
    assert event.reason_code == "ADMIN_SETTING_UPDATED"
    assert event.actor_id == "admin-1"
    assert event.before_data == {"value": None}
    assert event.after_data == {"value": "5000.00"}


def test_set_overwrites_value_and_records_previous(settings_components) -> None:
    service, factory = settings_components
    service.set(APP_LATEST_VERSION_KEY, "0.3.27", actor_id="admin-1")
    service.set(APP_LATEST_VERSION_KEY, "0.3.28", actor_id="admin-2", trace_id="trace-2")

    with factory() as session:
        stored = session.get(AppSetting, APP_LATEST_VERSION_KEY)
        events = session.scalars(
            select(AuditEvent)
            .where(AuditEvent.subject_id == APP_LATEST_VERSION_KEY)
            .order_by(AuditEvent.created_at)
        ).all()
    assert stored is not None and stored.value == "0.3.28"
    assert stored.updated_by == "admin-2"
    assert len(events) == 2
    assert events[0].before_data == {"value": None}
    assert events[1].before_data == {"value": "0.3.27"}
    assert events[1].after_data == {"value": "0.3.28"}



def test_values_use_unbounded_text_storage():
    from sqlalchemy import Text
    assert isinstance(AppSetting.__table__.c.value.type, Text)


def test_batch_write_audits_previous_values_and_snapshot_defaults(settings_components):
    from app.modules.settings.service import APP_UPDATE_SETTING_KEYS
    service, factory = settings_components
    before = {key: "old" for key in APP_UPDATE_SETTING_KEYS}
    after = {key: "new" for key in APP_UPDATE_SETTING_KEYS}
    service.set_many(before, actor_id="admin-1", trace_id="before")
    service.set_many(after, actor_id="admin-2", trace_id="after")
    assert service.get_many((*APP_UPDATE_SETTING_KEYS, "missing")) == {**after, "missing": None}
    with factory() as session:
        events = session.scalars(select(AuditEvent).where(AuditEvent.trace_id == "after")).all()
    assert len(events) == 5
    assert {event.subject_id for event in events} == set(APP_UPDATE_SETTING_KEYS)
    assert all(event.before_data == {"value": "old"} and event.after_data == {"value": "new"}
               and event.actor_id == "admin-2" for event in events)
