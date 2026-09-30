"""Real isolated PostgreSQL proofs; never connect to a production database."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time
import shutil
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout
from threading import Event
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, func, select, text

ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / 'services/business-api'))
from app.core.database import create_session_factory
from app.modules.audit.models import AuditEvent
from app.modules.settings.models import AppSetting
from app.modules.settings.service import APP_UPDATE_SETTING_KEYS, APP_IOS_UPDATE_SETTING_KEYS, SettingService

KEYS = APP_UPDATE_SETTING_KEYS + APP_IOS_UPDATE_SETTING_KEYS
BASELINE = dict(zip(KEYS, ('0.4.19','2188','3','android notes','https://www.liuhetong888.com/downloads/old.apk',
                          '0.4.7','2173','3','ios notes','https://www.liuhetong888.com/download?platform=ios&install=1')))
URL = 'https://www.liuhetong888.com/download?platform=android&install=1'


@pytest.fixture(scope='module')
def pg_url():
    name='starchat-publisher-cas-'+uuid4().hex[:12]
    image='sha256:7c688148e5e156d0e86df7ba8ae5a05a2386aaec1e2ad8e6d11bdf10504b1fb7'
    if not shutil.which('docker'):
        pytest.skip('isolated PostgreSQL proof requires Docker; no external database is used')
    for args in (['docker','info','--format','{{.ServerVersion}}'], ['docker','image','inspect',image]):
        if subprocess.run(args,capture_output=True).returncode:
            pytest.skip('isolated PostgreSQL proof requires the pinned local PostgreSQL 16.9 image and running Docker')
    subprocess.run(['docker','run','--detach','--name',name,'-e','POSTGRES_PASSWORD=local-test-only',
                    '-p','127.0.0.1::5432',image],check=True,capture_output=True,text=True)
    try:
        port=json.loads(subprocess.check_output(['docker','inspect',name],text=True))[0]['NetworkSettings']['Ports']['5432/tcp'][0]['HostPort']
        url=f'postgresql+psycopg://postgres:local-test-only@127.0.0.1:{port}/postgres'
        deadline=time.monotonic()+25
        while True:
            try:
                probe=create_engine(url)
                with probe.connect() as c: c.execute(text('SELECT 1'))
                probe.dispose();break
            except Exception:
                if time.monotonic()>=deadline: raise
                time.sleep(.1)
        yield url
    finally:
        subprocess.run(['docker','rm','--force',name],check=True,capture_output=True,text=True)


@pytest.fixture
def db(pg_url):
    schema='cas_'+uuid4().hex
    initial=create_engine(pg_url)
    with initial.begin() as c: c.execute(text('CREATE SCHEMA '+schema))
    initial.dispose()
    engine=create_engine(pg_url,connect_args={'options':'-csearch_path='+schema})
    AppSetting.__table__.create(engine);AuditEvent.__table__.create(engine)
    service=SettingService(create_session_factory(engine))
    service.set_many(BASELINE,actor_id='seed',trace_id='synthetic-seed')
    yield engine,service
    engine.dispose()


def load_module():
    path=ROOT/'scripts/release_settings.py'
    assert path.exists(), 'release settings atomic transaction helper is missing'
    spec=importlib.util.spec_from_file_location('release_settings',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


def payload():
    return dict(mode='apply',expected=BASELINE,values={'app_apk_url':URL},trace='synthetic-release',
                network_selection=True,existing_release={'version':'0.4.19','build':2188})


def audits(engine):
    with engine.connect() as c: return c.scalar(select(func.count()).select_from(AuditEvent))


def test_network_transaction_changes_only_url_and_one_audit(db):
    m=load_module();engine,service=db;before=audits(engine)
    after=m.transact_settings(engine,payload())
    assert after==BASELINE|{'app_apk_url':URL}
    assert service.get_many(KEYS)==after
    assert audits(engine)==before+1
    assert m.transact_settings(engine,payload()|{'expected':after})==after
    assert audits(engine)==before+1


@pytest.mark.parametrize('key',['app_update_notes','app_ios_update_notes','app_apk_url'])
def test_admin_drift_before_lock_refused_without_publish_write_or_audit(db,key):
    m=load_module();engine,service=db
    inspected=m.transact_settings(engine,{'mode':'inspect'})
    service.set(key,'admin revision',actor_id='admin')
    before=service.get_many(KEYS);count=audits(engine)
    with pytest.raises(RuntimeError,match='drift'):m.transact_settings(engine,payload()|{'expected':inspected})
    assert service.get_many(KEYS)==before
    assert audits(engine)==count


def test_network_missing_row_fails_closed_without_write_or_audit(db):
    m=load_module();engine,service=db
    with engine.begin() as c:c.execute(AppSetting.__table__.delete().where(AppSetting.key=='app_ios_update_notes'))
    before=service.get_many(KEYS);count=audits(engine)
    with pytest.raises(RuntimeError,match='missing'):m.transact_settings(engine,payload()|{'expected':before})
    assert service.get_many(KEYS)==before
    assert audits(engine)==count


def test_readback_failure_rolls_back_service_write_and_audit(db,monkeypatch):
    m=load_module();engine,service=db;count=audits(engine)
    class DriftReadback(SettingService):
        calls=0
        def get_many(self,keys):
            values=super().get_many(keys);self.calls+=1
            if self.calls==2:values['app_ios_update_notes']='unexpected readback'
            return values
    monkeypatch.setattr(m,'SettingService',DriftReadback)
    with pytest.raises(RuntimeError,match='readback'):m.transact_settings(engine,payload())
    assert service.get_many(KEYS)==BASELINE
    assert audits(engine)==count


@pytest.mark.parametrize('method',['set','set_many'])
@pytest.mark.parametrize('key',['app_update_notes','app_apk_url'])
def test_concurrent_administrator_waits_for_atomic_publish(db,monkeypatch,method,key):
    m=load_module();engine,service=db;locked=Event();release=Event()
    class PausedRead(SettingService):
        calls=0
        def get_many(self,keys):
            values=super().get_many(keys);self.calls+=1
            if self.calls==1:
                locked.set();assert release.wait(5), 'publisher pause timed out'
            return values
    monkeypatch.setattr(m,'SettingService',PausedRead)
    def administrator():
        if method=='set':service.set(key,'administrator won after publish',actor_id='admin')
        else:service.set_many({key:'administrator won after publish'},actor_id='admin')
    with ThreadPoolExecutor(max_workers=2) as pool:
        publishing=pool.submit(m.transact_settings,engine,payload())
        assert locked.wait(5)
        writing=pool.submit(administrator)
        try:
            with pytest.raises(FutureTimeout):writing.result(timeout=.2)
        finally:release.set()
        assert publishing.result(timeout=5)==BASELINE|{'app_apk_url':URL}
        writing.result(timeout=5)
    assert service.get(key)=='administrator won after publish'
    if key!='app_apk_url':assert service.get('app_apk_url')==URL


@pytest.mark.parametrize('values',[{'app_latest_build':'2189'},{'app_min_supported_build':'9999'},
                                  {'app_apk_url':URL,'app_ios_latest_build':'2174'}])
def test_network_rejects_other_setting_mutations_without_audit(db,values):
    m=load_module();engine,service=db;count=audits(engine)
    with pytest.raises(ValueError,match='URL only'):m.transact_settings(engine,payload()|{'values':values})
    assert service.get_many(KEYS)==BASELINE
    assert audits(engine)==count


@pytest.mark.parametrize('url',['https://foreign.invalid/app.apk','https://www.liuhetong888.com/downloads/another.apk',''])
def test_network_helper_refuses_other_url_without_write_or_audit(db,url):
    m=load_module();engine,service=db;count=audits(engine)
    with pytest.raises(ValueError,match='download entry'):
        m.transact_settings(engine,payload()|{'values':{'app_apk_url':url}})
    assert service.get_many(KEYS)==BASELINE
    assert audits(engine)==count


def test_network_rechecks_existing_release_inside_transaction(db):
    m=load_module();engine,service=db;count=audits(engine)
    with pytest.raises(RuntimeError,match='existing release'):
        m.transact_settings(engine,payload()|{'existing_release':{'version':'0.4.20','build':2189}})
    assert audits(engine)==count
    assert service.get_many(KEYS)==BASELINE


@pytest.mark.parametrize('values',[{'app_latest_version':'0.4.20','app_latest_build':'2189','app_apk_url':'new android'},
                                  {'app_ios_latest_version':'0.4.8','app_ios_latest_build':'2174','app_ios_download_url':'new ios'}])
def test_legacy_platform_publication_remains_atomic(db,values):
    m=load_module();engine,service=db;count=audits(engine)
    legacy=payload()|{'network_selection':False,'values':values}
    assert m.transact_settings(engine,legacy)==BASELINE|values
    assert service.get_many(KEYS)==BASELINE|values
    assert audits(engine)==count+3
