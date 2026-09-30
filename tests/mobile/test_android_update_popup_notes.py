"""Android 2193 popup notes are a one-key audited follow-up to the live release."""

import ast
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import types
from urllib.parse import urlsplit
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.engine import make_url


PUBLISHER = Path(__file__).parents[2] / 'scripts/publish_android_update_popup_notes.py'
NEW_NOTES = '修复 USDT 提现报价显示异常；优化聊天搜索、朋友圈视频与部分页面体验。'
STATIC_NAMES = (
    'download.html', 'downloads/android-release.json',
    'src/download-redirect.js', 'src/download-network.js',
    'src/download-network-selector.js',
)
REPO = Path(__file__).parents[2]
sys.path.insert(0, str(REPO / 'services/business-api'))
from app.core.database import create_session_factory  # noqa: E402
from app.modules.audit.models import AuditEvent  # noqa: E402
from app.modules.settings.models import AppSetting  # noqa: E402
from app.modules.settings.service import (  # noqa: E402
    APP_IOS_UPDATE_SETTING_KEYS, APP_UPDATE_SETTING_KEYS, SettingService,
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def load_publisher(monkeypatch):
    assert PUBLISHER.is_file(), 'Android 2193 popup publisher is missing'
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *_args: None))
    spec = importlib.util.spec_from_file_location('android_2193_popup', PUBLISHER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_fixture(tmp_path):
    root = tmp_path / 'frontend'
    root.mkdir()
    private = tmp_path / 'private'
    private.mkdir(mode=0o700)
    apk = root / 'downloads/ChatFlow-0.4.24-build2193-arm64.apk'
    apk.parent.mkdir()
    apk.write_bytes(b'fixed signed Android 2193 fixture')
    static = {
        'download.html': b'<html>Android 0.4.24 (2193)</html>',
        'downloads/android-release.json': b'{"version":"0.4.24","build":2193}',
        'src/download-redirect.js': b'export const redirect = 2193;',
        'src/download-network.js': b'export const network = 2193;',
        'src/download-network-selector.js': b'export const selector = 2193;',
    }
    for name, body in static.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    static_sha = {name: sha(body) for name, body in static.items()}
    record = {
        'platform': 'android', 'version': '0.4.24', 'build': 2193,
        'artifact_url': 'https://www.liuhetong888.com/downloads/' + apk.name,
        'artifact_bytes': apk.stat().st_size, 'artifact_sha256': sha(apk.read_bytes()),
        'signing_confirmed_by': 'test release',
        'source_commit': 'test-source', 'mobile_manifest_sha256': '1' * 64,
        'signer_sha256': '2' * 64, 'package': 'com.liuhetong.mobile',
        'abi': 'arm64-v8a', 'network_selection': True,
        'cdn_url': 'https://d12fjr06o6tga5.cloudfront.net/downloads/' + apk.name,
        'network_assets': {
            name.removeprefix('src/'): static_sha[name] for name in STATIC_NAMES
            if name.startswith('src/')
        },
    }
    before = {
        'app_latest_version': '0.4.24', 'app_latest_build': '2193',
        'app_min_supported_build': '3', 'app_update_notes': 'Old Android notes',
        'app_apk_url': 'https://www.liuhetong888.com/download?platform=android&install=1',
        'app_ios_latest_version': '0.4.20', 'app_ios_latest_build': '2189',
        'app_ios_min_supported_build': '3', 'app_ios_update_notes': 'Old iOS notes',
        'app_ios_download_url': 'https://www.liuhetong888.com/download?platform=ios&install=1',
    }
    calls = []
    current = dict(before)
    audit_rows = []

    def db(payload):
        calls.append(('db', payload))
        if payload['mode'] == 'apply':
            assert payload['expected'] == current
            assert payload['values'] == {'app_update_notes': NEW_NOTES}
            audit_rows.append({
                'subject_type': 'app_setting', 'key': 'app_update_notes',
                'before': current['app_update_notes'],
                'after': NEW_NOTES, 'action': 'settings.update',
                'result': 'SUCCESS', 'reason_code': 'ADMIN_SETTING_UPDATED',
            })
            current.update(payload['values'])
        return dict(current)

    def audit(payload):
        calls.append(('audit', payload))
        return list(audit_rows)

    def request(url, method='GET'):
        calls.append(('http', url, method))
        path = urlsplit(url).path
        if path.endswith('.apk'):
            assert method == 'HEAD', 'publisher must never download the APK'
            return {'Content-Length': str(apk.stat().st_size)}, b''
        assert method == 'GET'
        name = 'download.html' if path == '/download' else path.lstrip('/')
        data = (root / name).read_bytes()
        return {'Content-Length': str(len(data))}, data

    kwargs = {
        'request': request, 'db': db, 'audit': audit,
        'expected_release': dict(record), 'expected_static_sha256': static_sha,
    }
    return root, private, record, before, current, calls, kwargs


def test_preflight_checks_published_identity_without_setting_or_backup_write(
        tmp_path, monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, current, calls, kwargs = release_fixture(tmp_path)
    result = publisher.preflight(record, before, root, 'android-popup-2193-fixture', **kwargs)
    assert current == before
    assert result['artifact_sha256'] == record['artifact_sha256']
    assert result['settings_before'] == before
    assert [call[2] for call in calls if call[0] == 'http' and
            call[1].endswith('.apk')] == ['HEAD', 'HEAD']
    assert len([call for call in calls if call[0] == 'http' and
                call[2] == 'GET']) == len(STATIC_NAMES)
    assert not any(call[0] == 'db' and call[1]['mode'] == 'apply' for call in calls)
    assert not list(private.iterdir())


def test_execute_changes_only_android_notes_once_with_private_backup_and_audit(
        tmp_path, monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, current, calls, kwargs = release_fixture(tmp_path)
    backup = private / 'android-popup-2193'
    result = publisher.publish(
        record, before, root, backup, 'android-popup-2193-fixture',
        allowed_backup_root=private, **kwargs)
    expected = dict(before, app_update_notes=NEW_NOTES)
    assert current == expected
    assert result['settings_before'] == before
    assert result['settings_after'] == expected
    assert result['changed_keys'] == ['app_update_notes']
    assert result['audit_count'] == 1
    apply = [call[1] for call in calls if call[0] == 'db' and
             call[1]['mode'] == 'apply']
    assert len(apply) == 1
    assert apply[0]['values'] == {'app_update_notes': NEW_NOTES}
    assert apply[0]['expected'] == before
    if os.name == 'posix':
        assert backup.stat().st_mode & 0o777 == 0o700
    assert (backup / 'before.json').is_file()
    assert json.loads((backup / 'before.json').read_text(encoding='utf-8'))['audit_before'] == []
    assert (backup / 'release.json').is_file()
    assert (backup / 'result.json').is_file()


@pytest.mark.parametrize('drift', [
    'record', 'baseline', 'static', 'public', 'artifact', 'settings',
    'audit_trace', 'already_published',
])
def test_execute_refuses_drift_before_any_write(tmp_path, monkeypatch, drift):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, current, calls, kwargs = release_fixture(tmp_path)
    if drift == 'record':
        record['source_commit'] = 'other-source'
    elif drift == 'baseline':
        before['app_ios_latest_build'] = '2190'
    elif drift == 'static':
        (root / 'download.html').write_bytes(b'other page')
    elif drift == 'public':
        original = kwargs['request']

        def other_public(url, method='GET'):
            headers, data = original(url, method)
            return headers, (b'other page' if url.endswith('/download') else data)

        kwargs['request'] = other_public
    elif drift == 'artifact':
        (root / urlsplit(record['artifact_url']).path.lstrip('/')).write_bytes(
            b'other signed Android fixture!!')
    elif drift == 'settings':
        current['app_ios_latest_build'] = '2190'
    elif drift == 'audit_trace':
        kwargs['audit'] = lambda _payload: [{'key': 'app_update_notes'}]
    else:
        current['app_update_notes'] = NEW_NOTES
    backup = private / 'android-popup-2193'
    with pytest.raises(ValueError):
        publisher.publish(record, before, root, backup,
                          'android-popup-2193-fixture',
                          allowed_backup_root=private, **kwargs)
    assert not any(call[0] == 'db' and call[1]['mode'] == 'apply' for call in calls)
    assert not backup.exists()


def test_execute_rejects_reuse_of_private_backup_before_write(tmp_path, monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, _current, calls, kwargs = release_fixture(tmp_path)
    backup = private / 'android-popup-2193'
    backup.mkdir()
    with pytest.raises(ValueError, match='fresh private'):
        publisher.publish(record, before, root, backup,
                          'android-popup-2193-fixture',
                          allowed_backup_root=private, **kwargs)
    assert not any(call[0] == 'db' and call[1]['mode'] == 'apply' for call in calls)


def test_ambiguous_db_failure_is_not_retried_or_rolled_back(tmp_path, monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, current, calls, kwargs = release_fixture(tmp_path)
    original = kwargs['db']

    def ambiguous(payload):
        result = original(payload)
        if payload['mode'] == 'apply':
            raise RuntimeError('lost response after commit')
        return result

    kwargs['db'] = ambiguous
    backup = private / 'android-popup-2193'
    with pytest.raises(RuntimeError, match='lost response'):
        publisher.publish(record, before, root, backup,
                          'android-popup-2193-fixture',
                          allowed_backup_root=private, **kwargs)
    assert current['app_update_notes'] == NEW_NOTES
    assert len([call for call in calls if call[0] == 'db' and
                call[1]['mode'] == 'apply']) == 1
    assert (backup / 'before.json').is_file()
    assert (backup / 'outcome-unknown.json').is_file()
    assert not (backup / 'result.json').exists()


def test_incorrect_audit_after_write_is_reported_without_rollback(tmp_path,
                                                                   monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, current, calls, kwargs = release_fixture(tmp_path)
    kwargs['audit'] = lambda _payload: []
    backup = private / 'android-popup-2193'
    with pytest.raises(ValueError, match='audit'):
        publisher.publish(record, before, root, backup,
                          'android-popup-2193-fixture',
                          allowed_backup_root=private, **kwargs)
    assert current['app_update_notes'] == NEW_NOTES
    assert len([call for call in calls if call[0] == 'db' and
                call[1]['mode'] == 'apply']) == 1
    assert (backup / 'outcome-unknown.json').is_file()


def test_notes_adapter_uses_own_atomic_service_path_and_rejects_other_values(
        tmp_path, monkeypatch):
    publisher = load_publisher(monkeypatch)
    calls = []

    def check_output(command, input):
        calls.append((command, input))
        return b'{}'

    monkeypatch.setattr(publisher.subprocess, 'check_output', check_output)
    assert publisher.db_settings_notes({'mode': 'inspect'}) == {}
    assert len(calls) == 1
    command, script = calls[0]
    assert command[:4] == ['docker', 'exec', '-i', '-w']
    assert command[-3:-1] == ['python3', '-']
    assert json.loads(command[-1]) == {'mode': 'inspect'}
    assert b'SettingService' in script
    assert b'pg_advisory_xact_lock(1937006964, 1)' in script
    assert b'with_for_update()' in script
    assert b"join_transaction_mode='create_savepoint'" in script
    assert b'release_settings' not in script
    with pytest.raises(ValueError, match='notes only'):
        publisher.db_settings_notes({
            'mode': 'apply', 'expected': {},
            'values': {'app_latest_build': '9999'},
            'trace': 'android-popup-2193-fixture',
        })
    assert len(calls) == 1


def test_existing_production_release_settings_contract_rejects_notes_key():
    repo = Path(__file__).parents[2]
    source = repo / 'scripts/release_settings.py'
    if not source.is_file():
        source = Path('D:/pythonProject/outsource/StarChat/scripts/release_settings.py')
    if not source.is_file():
        pytest.skip('production release_settings.py source is not in this checkout')
    tree = ast.parse(source.read_text(encoding='utf-8'))
    allowed = next(ast.literal_eval(node.value) for node in tree.body
                   if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and
                           target.id == 'ANDROID_RELEASE_KEYS' for target in node.targets))
    assert allowed == {'app_latest_version', 'app_latest_build', 'app_apk_url'}
    assert 'app_update_notes' not in allowed
    assert 'invalid platform settings keys' in source.read_text(encoding='utf-8')


def test_notes_transaction_source_keeps_precheck_write_audit_in_one_pg_transaction(
        monkeypatch):
    publisher = load_publisher(monkeypatch)
    source = publisher.SETTINGS_SCRIPT
    assert 'with engine.begin() as connection:' in source
    assert "engine.dialect.name != 'postgresql'" in source
    assert 'pg_advisory_xact_lock(1937006964, 1)' in source
    assert '.with_for_update()' in source
    assert "join_transaction_mode='create_savepoint'" in source
    assert "service.set_many({'app_update_notes': EXPECTED_NOTES}" in source
    assert 'if before != expected:' in source
    assert 'if after != before | values:' in source


def test_audit_reader_checks_trace_across_all_subject_types(monkeypatch):
    publisher = load_publisher(monkeypatch)
    assert 'AuditEvent.subject_type==' not in publisher.AUDIT_SCRIPT
    assert "'subject_type':r.subject_type" in publisher.AUDIT_SCRIPT


def test_other_subject_trace_is_rejected_before_setting_write(tmp_path,
                                                              monkeypatch):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, _current, calls, kwargs = release_fixture(tmp_path)
    kwargs['audit'] = lambda _payload: [{
        'subject_type': 'user', 'key': 'not-a-setting',
    }]
    backup = private / 'android-popup-2193'
    with pytest.raises(ValueError, match='trace already exists'):
        publisher.publish(record, before, root, backup,
                          'android-popup-2193-fixture',
                          allowed_backup_root=private, **kwargs)
    assert not any(call[0] == 'db' and call[1]['mode'] == 'apply' for call in calls)
    assert not backup.exists()


@pytest.fixture(scope='module')
def isolated_postgres_url():
    """The same pinned local PostgreSQL image as release_settings tests."""
    image = 'sha256:7c688148e5e156d0e86df7ba8ae5a05a2386aaec1e2ad8e6d11bdf10504b1fb7'
    if not shutil.which('docker'):
        pytest.skip('isolated PostgreSQL proof requires Docker')
    for command in (
        ['docker', 'info', '--format', '{{.ServerVersion}}'],
        ['docker', 'image', 'inspect', image],
    ):
        if subprocess.run(command, capture_output=True).returncode:
            pytest.skip('pinned local PostgreSQL image or Docker daemon unavailable')
    name = 'starchat-popup-2193-' + uuid4().hex[:12]
    subprocess.run([
        'docker', 'run', '--detach', '--name', name,
        '-e', 'POSTGRES_PASSWORD=local-test-only', '-p', '127.0.0.1::5432', image,
    ], capture_output=True, check=True)
    try:
        port = json.loads(subprocess.check_output(['docker', 'inspect', name], text=True))[
            0]['NetworkSettings']['Ports']['5432/tcp'][0]['HostPort']
        url = f'postgresql+psycopg://postgres:local-test-only@127.0.0.1:{port}/postgres'
        deadline = time.monotonic() + 25
        while True:
            try:
                engine = create_engine(url)
                with engine.connect() as connection:
                    connection.execute(text('SELECT 1'))
                engine.dispose()
                break
            except Exception:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        yield url
    finally:
        subprocess.run(['docker', 'rm', '--force', name], capture_output=True, check=True)


@pytest.fixture
def isolated_popup_db(isolated_postgres_url):
    schema = 'popup_' + uuid4().hex
    admin = create_engine(isolated_postgres_url)
    with admin.begin() as connection:
        connection.execute(text('CREATE SCHEMA ' + schema))
    admin.dispose()
    url = make_url(isolated_postgres_url).set(
        query={'options': '-csearch_path=' + schema}).render_as_string(hide_password=False)
    engine = create_engine(url)
    AppSetting.__table__.create(engine)
    AuditEvent.__table__.create(engine)
    service = SettingService(create_session_factory(engine))
    baseline = {
        'app_latest_version': '0.4.24', 'app_latest_build': '2193',
        'app_min_supported_build': '3', 'app_update_notes': 'Old Android notes',
        'app_apk_url': 'https://www.liuhetong888.com/download?platform=android&install=1',
        'app_ios_latest_version': '0.4.20', 'app_ios_latest_build': '2189',
        'app_ios_min_supported_build': '3', 'app_ios_update_notes': 'Old iOS notes',
        'app_ios_download_url': 'https://www.liuhetong888.com/download?platform=ios&install=1',
    }
    service.set_many(baseline, actor_id='seed', trace_id='synthetic-seed')
    yield url, engine, service, baseline
    engine.dispose()


def run_atomic_script(publisher, url, payload):
    environment = dict(os.environ, BUSINESS_DATABASE_URL=url)
    environment['PYTHONPATH'] = str(REPO / 'services/business-api')
    return subprocess.run(
        [sys.executable, '-', json.dumps(payload)],
        input=publisher.SETTINGS_SCRIPT.encode('utf-8'),
        capture_output=True, env=environment,
    )


def count_popup_audits(engine, trace):
    with engine.connect() as connection:
        return connection.scalar(select(func.count()).select_from(AuditEvent).where(
            AuditEvent.trace_id == trace))


def test_real_pg_atomic_notes_transaction_changes_one_key_and_audit(
        isolated_popup_db, monkeypatch):
    publisher = load_publisher(monkeypatch)
    url, engine, service, baseline = isolated_popup_db
    trace = 'synthetic-android-popup-2193'
    result = run_atomic_script(publisher, url, {
        'mode': 'apply', 'expected': baseline,
        'values': {'app_update_notes': NEW_NOTES}, 'trace': trace,
    })
    assert result.returncode == 0, result.stderr.decode('utf-8', errors='replace')
    after = json.loads(result.stdout)
    assert after == dict(baseline, app_update_notes=NEW_NOTES)
    assert service.get_many(APP_UPDATE_SETTING_KEYS + APP_IOS_UPDATE_SETTING_KEYS) == after
    assert count_popup_audits(engine, trace) == 1
    with create_session_factory(engine)() as session:
        event = session.scalar(select(AuditEvent).where(AuditEvent.trace_id == trace))
        assert event.subject_type == 'app_setting'
        assert event.subject_id == 'app_update_notes'
        assert event.before_data == {'value': baseline['app_update_notes']}
        assert event.after_data == {'value': NEW_NOTES}


def test_real_pg_atomic_notes_transaction_rejects_drift_without_audit(
        isolated_popup_db, monkeypatch):
    publisher = load_publisher(monkeypatch)
    url, engine, service, baseline = isolated_popup_db
    service.set('app_ios_update_notes', 'concurrent administrator edit', actor_id='admin')
    trace = 'synthetic-android-popup-drift'
    result = run_atomic_script(publisher, url, {
        'mode': 'apply', 'expected': baseline,
        'values': {'app_update_notes': NEW_NOTES}, 'trace': trace,
    })
    assert result.returncode != 0
    assert b'Settings drift; no write' in result.stderr
    assert service.get('app_update_notes') == baseline['app_update_notes']
    assert service.get('app_ios_update_notes') == 'concurrent administrator edit'
    assert count_popup_audits(engine, trace) == 0


def test_real_pg_atomic_notes_transaction_rolls_back_failed_audit_insert(
        isolated_popup_db, monkeypatch):
    publisher = load_publisher(monkeypatch)
    url, engine, service, baseline = isolated_popup_db
    trace = 'synthetic-android-popup-rollback'
    with engine.begin() as connection:
        connection.execute(text('''
            CREATE FUNCTION reject_popup_audit() RETURNS trigger AS $$
            BEGIN
              IF NEW.trace_id = 'synthetic-android-popup-rollback' THEN
                RAISE EXCEPTION 'synthetic popup audit failure';
              END IF;
              RETURN NEW;
            END;
            $$ LANGUAGE plpgsql
        '''))
        connection.execute(text('''
            CREATE TRIGGER reject_popup_audit_insert BEFORE INSERT ON audit_events
            FOR EACH ROW EXECUTE FUNCTION reject_popup_audit()
        '''))
    result = run_atomic_script(publisher, url, {
        'mode': 'apply', 'expected': baseline,
        'values': {'app_update_notes': NEW_NOTES}, 'trace': trace,
    })
    assert result.returncode != 0
    assert b'synthetic popup audit failure' in result.stderr
    assert service.get_many(APP_UPDATE_SETTING_KEYS + APP_IOS_UPDATE_SETTING_KEYS) == baseline
    assert count_popup_audits(engine, trace) == 0


@pytest.mark.parametrize('trace', ['bad trace', '', 'x' * 101])
def test_invalid_trace_rejected_before_write(tmp_path, monkeypatch, trace):
    publisher = load_publisher(monkeypatch)
    root, private, record, before, _current, calls, kwargs = release_fixture(tmp_path)
    backup = private / 'android-popup-2193'
    with pytest.raises(ValueError, match='trace'):
        publisher.publish(record, before, root, backup, trace,
                          allowed_backup_root=private, **kwargs)
    assert not any(call[0] == 'db' and call[1]['mode'] == 'apply' for call in calls)
    assert not backup.exists()
