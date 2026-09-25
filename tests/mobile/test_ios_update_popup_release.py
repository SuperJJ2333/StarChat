"""The 2173 popup release changes only three iOS settings after public checks."""

import hashlib
import importlib.util
from pathlib import Path
import sys
import types
from urllib.parse import urlsplit

import pytest


REPO = Path(__file__).parents[2]
PUBLISHER = REPO / 'scripts/publish_ios_update_popup.py'
METADATA = REPO / 'scripts/release_metadata.py'
STATIC_NAMES = ('download.html', 'src/admin-home.js', 'downloads/ios/manifest.plist')
EXPECTED_DIFFERENCES = [
    'added Payload path: Payload/Runner.app/Frameworks/AppRuntime/ATHelper.dylib',
    'added Payload path: Payload/Runner.app/Frameworks/Partner/libutils.dylib',
    'added Payload path: Payload/Runner.app/flag',
    'Payload/Runner.app/Runner: Mach-O load commands changed for CPU 100000c',
]


def load_module(path, name):
    assert path.exists(), f'required publisher is missing: {path.name}'
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *_args: None))
    metadata = load_module(METADATA, 'popup_release_metadata')
    root = tmp_path / 'frontend'
    (root / 'downloads/ios').mkdir(parents=True)
    ipa = root / 'downloads/ios/ChatFlow-0.4.7-build2173.ipa'
    ipa.write_bytes(b'enterprise signed IPA fixture')
    artifact_url = f'{metadata.BASE}/downloads/ios/{ipa.name}'
    record = {
        'platform': 'ios', 'version': '0.4.7', 'build': 2173,
        'artifact_url': artifact_url, 'artifact_bytes': ipa.stat().st_size,
        'bundle_id': metadata.BUNDLE, 'signing_confirmed_by': 'release owner',
        'ios_ci_candidate_sha256': '0' * 64,
        'publication_scope': 'website_ios_links_only_no_app_update_settings',
        'ios_ipa_evidence': {'sha256': sha(ipa.read_bytes()),
                             'artifact_bytes': ipa.stat().st_size},
        'payload_exception': {
            'authorized_by': 'user direct distribution',
            'reason': 'Existing enterprise signer injects these exact libraries',
            'candidate_sha256': '0' * 64,
            'final_sha256': sha(ipa.read_bytes()),
            'expected_differences': EXPECTED_DIFFERENCES,
            'payload_comparison_status': 'fail',
        },
    }
    label = f'{record["version"]}（{record["build"]}）'
    (root / 'download.html').write_text(
        f'<p>{label}</p><a href="{urlsplit(artifact_url).path}" download>IPA</a>'
        f'<a href="itms-services://?action=download-manifest&amp;url={metadata.MANIFEST}">安装</a>',
        encoding='utf-8')
    (root / 'src').mkdir()
    (root / 'src/admin-home.js').write_text(label * 3, encoding='utf-8')
    (root / 'downloads/ios/manifest.plist').write_bytes(metadata.manifest(record))
    settings = {
        'app_latest_version': '0.4.7', 'app_latest_build': '2172',
        'app_min_supported_build': '3', 'app_update_notes': 'Android notes',
        'app_apk_url': f'{metadata.BASE}/downloads/android-2172.apk',
        'app_ios_latest_version': '0.3.102', 'app_ios_latest_build': '2144',
        'app_ios_min_supported_build': '3', 'app_ios_update_notes': 'Old iOS notes',
        'app_ios_download_url': metadata.INSTALL,
    }
    record['expected_app_settings_before'] = dict(settings)
    static_result = {
        'artifact_url': artifact_url, 'artifact_sha256': sha(ipa.read_bytes()),
        'artifact_bytes': ipa.stat().st_size,
        'static_after_sha256': {
            name: sha((root / name).read_bytes()) for name in STATIC_NAMES},
        'settings_before': dict(settings), 'settings_after': dict(settings),
        'payload_exception': record['payload_exception'],
    }
    calls = []
    current = dict(settings)
    audit_rows = []

    def db(payload):
        calls.append(payload)
        if payload['mode'] == 'apply':
            assert payload['expected'] == current
            for key, value in payload['values'].items():
                audit_rows.append({'key': key, 'before': current[key], 'after': value,
                                   'action': 'settings.update', 'result': 'SUCCESS',
                                   'reason_code': 'ADMIN_SETTING_UPDATED'})
            current.update(payload['values'])
        return dict(current)

    def audit(payload):
        calls.append(('audit', payload))
        return list(audit_rows)

    def request(url, method='GET'):
        calls.append((url, method))
        path = urlsplit(url).path
        assert not (path.endswith('.ipa') and method == 'GET'), 'no full public IPA GET'
        data = (root / ('download.html' if path == '/download'
                        else path.lstrip('/'))).read_bytes()
        if method == 'HEAD':
            return {'Content-Length': str(len(data))}, b''
        return ({'Content-Type': 'application/xml', 'Cache-Control': 'no-store'}, data)

    return root, record, static_result, settings, current, calls, db, audit, request


def test_popup_publisher_updates_only_ios_version_build_notes_after_public_preflight(
        tmp_path, monkeypatch):
    root, record, static_result, before, current, calls, db, audit, request = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_update_popup_publisher')
    notes = '优化 iOS 登录与本地聊天身份恢复；完善群公告、朋友圈、个人中心及钱包体验。'
    backup = tmp_path / 'private' / 'popup-2173'
    result = publisher.publish(
        record, static_result, root, backup, notes,
        'ios-popup-0.4.7-2173-20260925', request=request, db=db, audit=audit,
        allowed_backup_root=tmp_path / 'private')
    expected = dict(before, app_ios_latest_version='0.4.7',
                    app_ios_latest_build='2173', app_ios_update_notes=notes)
    assert current == expected
    assert result['settings_before'] == before
    assert result['settings_after'] == expected
    assert result['changed_keys'] == [
        'app_ios_latest_version', 'app_ios_latest_build', 'app_ios_update_notes']
    apply = [call for call in calls if isinstance(call, dict) and call['mode'] == 'apply']
    assert len(apply) == 1
    assert apply[0]['values'] == {key: expected[key] for key in result['changed_keys']}
    assert apply[0]['expected'] == before
    assert any(isinstance(call, tuple) and call[1] == 'HEAD'
               and call[0] == record['artifact_url'] for call in calls)
    assert (backup / 'before.json').is_file()
    assert (backup / 'result.json').is_file()
    assert result['audit_count'] == 3


@pytest.mark.parametrize('drift', ['static', 'settings', 'artifact'])
def test_popup_publisher_refuses_drift_before_audited_write(tmp_path, monkeypatch,
                                                            drift):
    root, record, static_result, _before, current, calls, db, audit, request = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_update_popup_publisher_drift')
    if drift == 'static':
        (root / 'download.html').write_bytes(b'other website release')
    elif drift == 'settings':
        current['app_latest_build'] = '2173'
    else:
        (root / urlsplit(record['artifact_url']).path.lstrip('/')).write_bytes(
            b'other signed IPA same length!'[:record['artifact_bytes']])
    backup = tmp_path / 'private' / 'popup-2173'
    with pytest.raises(ValueError, match='drift|mismatch'):
        publisher.publish(record, static_result, root, backup, 'New iOS notes',
                          'ios-popup-0.4.7-2173-20260925', request=request, db=db,
                          audit=audit, allowed_backup_root=tmp_path / 'private')
    assert not any(isinstance(call, dict) and call['mode'] == 'apply' for call in calls)
    assert not backup.exists()


def test_popup_publisher_refuses_reused_audit_trace_before_write(tmp_path,
                                                                 monkeypatch):
    root, record, static_result, _before, _current, calls, db, _audit, request = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_update_popup_publisher_audit')
    backup = tmp_path / 'private' / 'popup-2173'
    with pytest.raises(ValueError, match='audit trace already exists'):
        publisher.publish(
            record, static_result, root, backup, 'New iOS notes',
            'ios-popup-0.4.7-2173-20260925', request=request, db=db,
            audit=lambda _payload: [{'key': 'app_ios_latest_build'}],
            allowed_backup_root=tmp_path / 'private')
    assert not any(isinstance(call, dict) and call['mode'] == 'apply' for call in calls)
    assert not backup.exists()
