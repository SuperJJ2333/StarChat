"""Run only against the task's isolated restored PostgreSQL 16 database.

MOMENTS_TEST_DATABASE_URL must be supplied by the isolation harness, never the
production DATABASE_URL. Each test uses and drops only its own random schema.
"""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from threading import Event, current_thread
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, text, select, func

from test_moments_api import ctx  # Imports all model registrations, no live app.
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus
from app.modules.moments.models import Moment, MomentDraft
from app.modules.moments.service import MomentsService


@pytest.fixture
def pg_factory():
    url=os.getenv("MOMENTS_TEST_DATABASE_URL")
    if not url:
        pytest.skip("Requires task-owned isolated PostgreSQL database")
    schema="moments_case_"+uuid4().hex
    admin=create_engine(url)
    with admin.begin() as conn:
        assert conn.dialect.name=="postgresql"
        assert conn.execute(text("SHOW server_version_num")).scalar_one().startswith("16")
        conn.execute(text('CREATE SCHEMA "'+schema+'"'))
    engine=create_engine(url,connect_args={"options":"-csearch_path="+schema},pool_size=5)
    try:
        # Only the Moment publication/draft dependency closure belongs to this
        # test. Creating unrelated financial tables through SQLite-oriented
        # model defaults is neither required nor an accurate migration test.
        required = (
            "users", "moments", "moment_drafts", "friendships",
            "contact_profiles", "audit_events", "outbox_events",
        )
        Base.metadata.create_all(engine, tables=[Base.metadata.tables[name] for name in required])
        factory=create_session_factory(engine)
        now=datetime.now(timezone.utc)
        with factory.begin() as session:
            session.add(User(id="synthetic",username="synthetic",username_normalized="synthetic",email="synthetic@example.test",email_normalized="synthetic@example.test",password_hash="synthetic",status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
        yield engine,factory
    finally:
        engine.dispose()
        with admin.begin() as conn:
            conn.execute(text('DROP SCHEMA "'+schema+'" CASCADE'))
        admin.dispose()


@pytest.mark.parametrize("first",["clear","save"])
def test_locked_clear_and_save_never_delete_newer_draft(pg_factory,first):
    engine,factory=pg_factory
    service=MomentsService(factory)
    old={"text":"old","nested":{"flag":True}}
    new={"text":"new","nested":{"flag":True}}
    service.save_draft("synthetic",old)
    locked,attempted,release=Event(),Event(),Event()
    def before(conn,cursor,statement,parameters,context,executemany):
        if "moment_drafts" in statement and "FOR UPDATE" in statement and current_thread().name.endswith("second"):
            attempted.set()
    def after(conn,cursor,statement,parameters,context,executemany):
        if "moment_drafts" in statement and "FOR UPDATE" in statement and current_thread().name.endswith("first"):
            locked.set()
            assert release.wait(10)
    event.listen(engine,"before_cursor_execute",before)
    event.listen(engine,"after_cursor_execute",after)
    def run(operation,name):
        current_thread().name=name
        return service.clear_draft_if_unchanged("synthetic",old) if operation=="clear" else service.save_draft("synthetic",new)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            a=pool.submit(run,first,"moment-first")
            assert locked.wait(10)
            b=pool.submit(run,"save" if first=="clear" else "clear","moment-second")
            assert attempted.wait(10)
            assert not b.done()
            release.set()
            values=[a.result(timeout=10),b.result(timeout=10)]
        assert values[0 if first=="clear" else 1] is (first=="clear")
        assert service.draft("synthetic")==new
    finally:
        release.set()
        event.remove(engine,"before_cursor_execute",before)
        event.remove(engine,"after_cursor_execute",after)


@pytest.mark.parametrize("changed",[False,True])
def test_publish_idempotency_is_serialized_and_fingerprint_preserved(pg_factory,changed):
    _,factory=pg_factory
    service=MomentsService(factory)
    start=Event()
    def publish(body):
        assert start.wait(10)
        try:
            return service.create("synthetic",{"visibility":"SELF","text":body},"synthetic-key").id
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=2) as pool:
        a=pool.submit(publish,"same")
        b=pool.submit(publish,"different" if changed else "same")
        start.set()
        result=[a.result(timeout=10),b.result(timeout=10)]
    with factory() as s:
        assert s.scalar(select(func.count()).select_from(Moment))==1
        assert s.scalar(select(Moment.request_fingerprint))
    if changed:
        assert result.count("IDEMPOTENCY_CONFLICT")==1
    else:
        assert result[0]==result[1]


def test_json_type_edit_is_persisted_and_old_snapshot_cannot_clear(pg_factory):
    _,factory=pg_factory
    service=MomentsService(factory)
    old={"text":"same","nested":{"flag":True}}
    new={"text":"same","nested":{"flag":1}}
    service.save_draft("synthetic",old)
    service.save_draft("synthetic",new)
    actual=service.draft("synthetic")
    assert type(actual["nested"]["flag"]) is int
    assert service.clear_draft_if_unchanged("synthetic",old) is False
    assert service.clear_draft_if_unchanged("synthetic",new) is True
