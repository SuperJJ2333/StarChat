"""Actual isolated PostgreSQL, using the repository's pinned Docker fixture."""
from pathlib import Path
import sys
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from threading import Event
from uuid import uuid4
import pytest
from sqlalchemy import create_engine,select,text,func

HERE=Path(__file__).parent
ROOT=HERE.parents[5]
sys.path.insert(0,str(ROOT/'tests/mobile'))
import test_release_settings as existing
pg_url=existing.pg_url
from app.core.database import create_session_factory
from app.modules.settings.models import AppSetting
from app.modules.settings.service import SettingService
from app.modules.audit.models import AuditEvent
import app.modules.settings.service as service_module
import release_2216 as release
import settings_2216 as target

BASELINE=release.read_json(HERE/'settings-before.json')

@pytest.fixture
def db(pg_url):
    schema='release2216_'+uuid4().hex
    initial=create_engine(pg_url)
    with initial.begin() as connection:connection.execute(text('CREATE SCHEMA '+schema))
    initial.dispose()
    engine=create_engine(pg_url,connect_args={'options':'-csearch_path='+schema})
    AppSetting.__table__.create(engine);AuditEvent.__table__.create(engine)
    service=SettingService(create_session_factory(engine))
    service.set_many(BASELINE,actor_id='synthetic-seed',trace_id='seed-2216')
    try:yield engine,service
    finally:engine.dispose()

def payload():return {'mode':'apply','expected':BASELINE,'after':release.settings_target(BASELINE),'trace':'synthetic-2216-publication'}
def audits(engine):
    with engine.connect() as connection:return connection.scalar(select(func.count()).select_from(AuditEvent))

def test_three_keys_and_exact_three_audits_commit_together(db):
    engine,service=db;count=audits(engine)
    assert target.transact(engine,payload())==release.settings_target(BASELINE)
    assert service.get_many(target.KEYS)==release.settings_target(BASELINE)
    assert audits(engine)==count+3

def test_ios_drift_is_refused_without_settings_or_audit_write(db):
    engine,service=db
    service.set('app_ios_update_notes','concurrent iOS notes',actor_id='synthetic-admin')
    before=service.get_many(target.KEYS);count=audits(engine)
    with pytest.raises(RuntimeError,match='CAS drift'):target.transact(engine,payload())
    assert service.get_many(target.KEYS)==before
    assert audits(engine)==count

def test_readback_failure_rolls_back_all_three_values_and_audits(db,monkeypatch):
    engine,service=db;count=audits(engine)
    class BadReadback(SettingService):
        calls=0
        def get_many(self,keys):
            values=super().get_many(keys);self.calls+=1
            if self.calls==2:values['app_ios_update_notes']='simulated bad readback'
            return values
    monkeypatch.setattr(service_module,'SettingService',BadReadback)
    with pytest.raises(RuntimeError,match='readback'):target.transact(engine,payload())
    assert service.get_many(target.KEYS)==BASELINE
    assert audits(engine)==count

def test_used_audit_trace_refused_without_any_setting_or_audit_write(db):
    engine,service=db
    service.set('app_ios_update_notes',BASELINE['app_ios_update_notes']+' temporary',actor_id='synthetic-admin',trace_id=payload()['trace'])
    service.set('app_ios_update_notes',BASELINE['app_ios_update_notes'],actor_id='synthetic-admin',trace_id='restore-baseline')
    count=audits(engine)
    with pytest.raises(RuntimeError,match='audit trace already exists'):target.transact(engine,payload())
    assert service.get_many(target.KEYS)==BASELINE
    assert audits(engine)==count

@pytest.mark.parametrize('method',['set','set_many'])
def test_concurrent_admin_waits_until_three_key_publication_commits(db,monkeypatch,method):
    engine,service=db;locked=Event();resume=Event()
    class PausedRead(SettingService):
        calls=0
        def get_many(self,keys):
            values=super().get_many(keys);self.calls+=1
            if self.calls==1:
                locked.set();assert resume.wait(5)
            return values
    monkeypatch.setattr(service_module,'SettingService',PausedRead)
    def administrator():
        if method=='set':service.set('app_ios_update_notes','admin-after-release',actor_id='synthetic-admin')
        else:service.set_many({'app_ios_update_notes':'admin-after-release'},actor_id='synthetic-admin')
    with ThreadPoolExecutor(max_workers=2) as pool:
        publishing=pool.submit(target.transact,engine,payload())
        assert locked.wait(5)
        writing=pool.submit(administrator)
        try:
            with pytest.raises(FutureTimeout):writing.result(timeout=.2)
        finally:resume.set()
        assert publishing.result(timeout=5)==release.settings_target(BASELINE)
        writing.result(timeout=5)
    assert service.get('app_ios_update_notes')=='admin-after-release'
    assert service.get('app_latest_build')=='2216'
