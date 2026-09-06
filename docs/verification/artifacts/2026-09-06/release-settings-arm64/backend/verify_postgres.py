"""Run with TEST_DATABASE_URL against disposable PostgreSQL, no pytest needed.

Optionally set SETTINGS_MIGRATION to the absolute 0038 migration file path.
Creates/removes only a randomly named verification schema; never uses public tables.
"""
import importlib.util
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier, Event
from uuid import uuid4

from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import create_engine, event, select, text
from sqlalchemy.exc import DBAPIError

from app.core.database import create_session_factory
from app.modules.audit.models import AuditEvent
from app.modules.settings.models import AppSetting
from app.modules.settings.service import APP_UPDATE_SETTING_KEYS, SettingService


def main():
    database_url = os.environ["TEST_DATABASE_URL"]
    admin_engine = create_engine(database_url)
    assert admin_engine.dialect.name == "postgresql", "PostgreSQL is required"
    schema = "settings_verify_" + uuid4().hex
    with admin_engine.begin() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    engine = create_engine(database_url, connect_args={"options": f"-csearch_path={schema}"})
    migration_path = Path(os.environ.get("SETTINGS_MIGRATION", "migrations/versions/0038_app_settings_text.py"))
    spec = importlib.util.spec_from_file_location("settings_migration", migration_path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)

    def migrate(action):
        with engine.begin() as connection:
            with Operations.context(MigrationContext.configure(connection)):
                getattr(migration, action)()

    def snapshot():
        return service.get_many(APP_UPDATE_SETTING_KEYS)

    def publish(revision):
        service.set_many({key: revision for key in APP_UPDATE_SETTING_KEYS}, actor_id="verify-admin", trace_id=revision)

    try:
        with engine.begin() as connection:
            connection.execute(text('CREATE TABLE app_settings (key VARCHAR(64) PRIMARY KEY, value VARCHAR(255) NOT NULL, updated_by VARCHAR(36) NOT NULL, updated_at TIMESTAMPTZ NOT NULL)'))
            AuditEvent.__table__.create(connection)
        factory = create_session_factory(engine)
        service = SettingService(factory)
        service.set("legacy", "unchanged", actor_id="verify-admin")
        try:
            service.set("long-before", "长" * 256, actor_id="verify-admin")
            raise AssertionError("VARCHAR(255) did not reject long value")
        except DBAPIError:
            pass
        migrate("upgrade")
        assert service.get("legacy") == "unchanged"
        service.set("long-notes", "更" * 2000, actor_id="verify-admin")
        service.set("long-url", "https://example.com/" + "a" * 480, actor_id="verify-admin")
        assert len(service.get("long-notes")) == 2000
        assert len(service.get("long-url")) == 500
        try:
            migrate("downgrade")
            raise AssertionError("unsafe narrowing succeeded")
        except DBAPIError as exc:
            assert "Cannot narrow" in str(exc)
        assert len(service.get("long-notes")) == 2000
        with engine.connect() as connection:
            assert connection.scalar(text("SELECT data_type FROM information_schema.columns WHERE table_schema = :schema AND table_name = 'app_settings' AND column_name = 'value'"), {"schema": schema}) == "text"
        service.set("long-notes", "short", actor_id="verify-admin")
        service.set("long-url", "short", actor_id="verify-admin")
        migrate("downgrade")
        assert service.get("legacy") == "unchanged"
        migrate("upgrade")
        print("PASS: VARCHAR rejection, TEXT Unicode/URL round trip, guarded downgrade and re-upgrade")

        barrier = Barrier(2)
        def first_publish(revision):
            barrier.wait(timeout=10)
            publish(revision)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(first_publish, revision) for revision in ("first-a", "first-b")]
            for future in futures:
                future.result(timeout=20)
        assert len(set(snapshot().values())) == 1
        with factory() as session:
            events = session.scalars(select(AuditEvent).where(AuditEvent.trace_id.in_(("first-a", "first-b")))).all()
        assert len(events) == 10
        previous = {trace: {row.before_data["value"] for row in events if row.trace_id == trace} for trace in ("first-a", "first-b")}
        assert all(len(values) == 1 for values in previous.values())
        assert sum(values == {None} for values in previous.values()) == 1
        print("PASS: competing initial publishers serialized with consistent audit before-values")

        before = snapshot()
        with factory() as session:
            audit_before = set(session.scalars(select(AuditEvent.id)))
        def fail_audit(mapper, connection, target):
            if target.subject_id == APP_UPDATE_SETTING_KEYS[3]:
                raise RuntimeError("injected audit failure")
        event.listen(AuditEvent, "before_insert", fail_audit)
        try:
            try:
                publish("failed-revision")
                raise AssertionError("fault injection did not fire")
            except RuntimeError as exc:
                assert str(exc) == "injected audit failure"
        finally:
            event.remove(AuditEvent, "before_insert", fail_audit)
        assert snapshot() == before
        with factory() as session:
            assert set(session.scalars(select(AuditEvent.id))) == audit_before
        print("PASS: settings and audit failure rolls back entire publication")

        start = Barrier(3)
        stop = Event()
        def writer(prefix):
            start.wait(timeout=10)
            for number in range(30):
                publish(f"{prefix}-{number}")
        def reader():
            start.wait(timeout=10)
            reads = 0
            while not stop.is_set() or reads < 30:
                values = snapshot()
                assert len(set(values.values())) == 1, "mixed revision"
                reads += 1
            return reads
        with ThreadPoolExecutor(max_workers=3) as pool:
            readers = pool.submit(reader)
            writers = [pool.submit(writer, prefix) for prefix in ("publisher-a", "publisher-b")]
            try:
                for future in writers:
                    future.result(timeout=40)
            finally:
                stop.set()
            reads = readers.result(timeout=10)
        assert len(set(snapshot().values())) == 1
        print(f"PASS: 60 competing publications; {reads} coherent snapshot reads")
    finally:
        engine.dispose()
        with admin_engine.begin() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin_engine.dispose()


if __name__ == "__main__":
    main()
