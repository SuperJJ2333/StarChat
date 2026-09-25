"""The link-only iOS publisher must never change app update settings."""

import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import sys
import types
from urllib.parse import urlsplit

import pytest


REPO = Path(__file__).parents[2]
PUBLISHER = REPO / 'scripts/publish_ios_static_links.py'
METADATA = REPO / 'scripts/release_metadata.py'
STATIC_NAMES = ('download.html', 'src/admin-home.js', 'downloads/ios/manifest.plist')
DIFFERENCES = [
    'added Payload path: Payload/Runner.app/Frameworks/AppRuntime/ATHelper.dylib',
    'added Payload path: Payload/Runner.app/Frameworks/Partner/libutils.dylib',
    'added Payload path: Payload/Runner.app/flag',
    'Payload/Runner.app/Runner: Mach-O load commands changed for CPU 100000c',
]


def load_module(path, name):
    if not path.exists():
        pytest.fail(f'required publisher is missing: {path.name}')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixture(tmp_path, monkeypatch):
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *_args: None))
    release = load_module(METADATA, 'test_release_metadata')
    root = tmp_path / 'frontend'
    (root / 'src').mkdir(parents=True)
    (root / 'downloads/ios').mkdir(parents=True)
    for name in STATIC_NAMES[:2]:
        (root / name).write_bytes((REPO / 'frontend' / name).read_bytes())
    old = dict(platform='ios', version='0.3.102', build=2144,
               artifact_url=f'{release.BASE}/downloads/ChatFlow-0.3.102-build2144-ios.ipa',
               artifact_bytes=44218488, bundle_id=release.BUNDLE,
               signing_confirmed_by='original release owner',
               ios_ci_candidate_sha256='0' * 64)
    (root / STATIC_NAMES[2]).write_bytes(release.manifest(old))
    source = tmp_path / 'signed.ipa'
    source.write_bytes(b'final enterprise IPA fixture')
    candidate = tmp_path / 'ci.ipa'
    candidate.write_bytes(b'CI IPA fixture')
    record = dict(platform='ios', version='0.4.7', build=2173,
                  artifact_url=f'{release.BASE}/downloads/ios/ChatFlow-0.4.7-build2173.ipa',
                  artifact_bytes=source.stat().st_size, bundle_id=release.BUNDLE,
                  signing_confirmed_by='user returned enterprise signed IPA',
                  ios_ci_candidate_sha256=sha(candidate.read_bytes()),
                  ios_legacy_application_identifier=release.LEGACY_IOS_APP_ID,
                  ios_ipa_evidence={'sha256': sha(source.read_bytes()),
                                    'artifact_bytes': source.stat().st_size,
                                    'team_id': 'ZXB3TS7QD4'})
    record['static_before_sha256'] = {
        name: sha((root / name).read_bytes()) for name in STATIC_NAMES}
    record['payload_exception'] = {
        'candidate_sha256': record['ios_ci_candidate_sha256'],
        'final_sha256': record['ios_ipa_evidence']['sha256'],
        'expected_differences': DIFFERENCES,
        'reason': 'Temporary enterprise signing requires the known injected libraries.',
        'authorized_by': 'user direct-publish request 2026-09-25',
    }
    settings = {'app_ios_latest_version': '0.3.102', 'app_ios_latest_build': '2144',
                'app_ios_download_url': release.INSTALL,
                'app_ios_min_supported_build': '3', 'app_ios_update_notes': 'old notes',
                'app_latest_version': '0.4.7', 'app_latest_build': '2172',
                'app_min_supported_build': '3', 'app_update_notes': 'android notes',
                'app_apk_url': f'{release.BASE}/downloads/latest-arm64.apk'}
    record['expected_app_settings_before'] = dict(settings)
    db_calls = []

    def db(payload):
        db_calls.append(payload)
        assert payload == {'mode': 'inspect'}
        return dict(settings)

    def request(url, method='GET'):
        path = urlsplit(url).path
        if path == '/download':
            data = (root / 'download.html').read_bytes()
        elif path == '/src/admin-home.js':
            data = (root / 'src/admin-home.js').read_bytes()
        else:
            data = (root / path.lstrip('/')).read_bytes()
        if method == 'HEAD':
            return {'Content-Length': str(len(data))}, b''
        return ({'Content-Type': 'application/xml', 'Cache-Control': 'no-store'}, data)

    def compare(_candidate, _final):
        return dict(candidate_sha256=record['ios_ci_candidate_sha256'],
                    final_sha256=record['ios_ipa_evidence']['sha256'],
                    status='fail', differences=list(DIFFERENCES),
                    payload_path_count=521, final_payload_path_count=524)

    return (root, source, candidate, record, settings, db_calls, db, request,
            compare, release)


def test_exactly_authorized_payload_exception_publishes_static_only(tmp_path, monkeypatch):
    root, source, candidate, record, settings, db_calls, db, request, compare, release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    backup = tmp_path / 'private-backup'
    result = publisher.publish(record, root, source, candidate, backup,
                               request=request, db=db,
                               inspector=lambda _path, _record: record['ios_ipa_evidence'],
                               comparator=compare)
    destination = root / urlsplit(record['artifact_url']).path.lstrip('/')
    assert destination.read_bytes() == source.read_bytes()
    assert plistlib.loads((root / STATIC_NAMES[2]).read_bytes())['items'][0]['assets'][0]['url'] == record['artifact_url']
    assert b'0.4.7' in (root / 'download.html').read_bytes()
    assert (root / 'src/admin-home.js').read_bytes().count('0.4.7'.encode()) == 3
    assert [call['mode'] for call in db_calls] == ['inspect', 'inspect']
    assert result['settings_before'] == result['settings_after'] == settings
    assert (backup / 'before.json').exists()
    assert (backup / 'payload-comparison.json').exists()
    assert (backup / 'result.json').exists()
    if os.name != 'nt':
        assert (backup.stat().st_mode & 0o777) == 0o700


@pytest.mark.parametrize('mutate', [
    lambda r: r['payload_exception'].update(final_sha256='f' * 64),
    lambda r: r['payload_exception'].update(expected_differences=DIFFERENCES[:-1]),
    lambda r: r['payload_exception'].update(reason=''),
])
def test_waiver_must_name_exact_final_sha_and_all_differences(tmp_path, monkeypatch, mutate):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    before = {name: (root / name).read_bytes() for name in STATIC_NAMES}
    mutate(record)
    with pytest.raises(ValueError, match='payload exception'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()
    assert all((root / name).read_bytes() == data for name, data in before.items())


def test_changed_static_fails_before_immutable_ipa_is_exposed(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    (root / 'download.html').write_bytes((root / 'download.html').read_bytes() + b'concurrent')
    with pytest.raises(ValueError, match='static drift'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()
    assert not (root / urlsplit(record['artifact_url']).path.lstrip('/')).exists()


def test_public_check_failure_restores_static_without_touching_settings(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, db_calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    before = {name: (root / name).read_bytes() for name in STATIC_NAMES}

    def failed_request(url, method='GET'):
        if url.endswith('/src/admin-home.js'):
            raise OSError('public route unavailable')
        return request(url, method)

    with pytest.raises(OSError, match='public route unavailable'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=failed_request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert all((root / name).read_bytes() == data for name, data in before.items())
    assert [call['mode'] for call in db_calls] == ['inspect']
    assert not (tmp_path / 'backup/result.json').exists()
    assert not (root / urlsplit(record['artifact_url']).path.lstrip('/')).exists()


def test_ipa_sha_mismatch_refuses_before_backup(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    record['ios_ipa_evidence']['sha256'] = 'f' * 64
    record['payload_exception']['final_sha256'] = 'f' * 64
    with pytest.raises(ValueError, match='IPA SHA256'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()


def test_payload_exception_cannot_expand_to_new_signer_changes(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    expanded = list(DIFFERENCES) + ['resource bytes changed: Payload/Runner.app/secret']
    record['payload_exception']['expected_differences'] = expanded

    def expanded_compare(_candidate, _final):
        report = compare(_candidate, _final)
        report['differences'] = expanded
        return report

    with pytest.raises(ValueError, match='payload exception'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=expanded_compare)
    assert not (tmp_path / 'backup').exists()


def test_static_symlink_is_rejected_before_backup(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    outside = tmp_path / 'outside.html'
    outside.write_bytes((root / 'download.html').read_bytes())
    (root / 'download.html').unlink()
    try:
        (root / 'download.html').symlink_to(outside)
    except OSError as exc:
        pytest.skip(f'OS disallows symlinks: {exc}')
    with pytest.raises(ValueError, match='symlink'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert outside.read_bytes() == (REPO / 'frontend/download.html').read_bytes()
    assert not (tmp_path / 'backup').exists()


def test_destination_symlink_is_rejected_before_backup(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    destination = root / urlsplit(record['artifact_url']).path.lstrip('/')
    try:
        destination.symlink_to(source)
    except OSError as exc:
        pytest.skip(f'OS disallows symlinks: {exc}')
    with pytest.raises(ValueError, match='symlink'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()


def test_backup_location_must_be_below_private_verification_root(tmp_path):
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    allowed = tmp_path / 'private/artifacts'
    allowed.mkdir(parents=True)
    publisher.validate_backup_location(allowed / 'new-release', allowed_root=allowed)
    with pytest.raises(ValueError, match='backup'):
        publisher.validate_backup_location(tmp_path / 'public-backup', allowed_root=allowed)
    with pytest.raises(ValueError, match='backup'):
        publisher.validate_backup_location(allowed, allowed_root=allowed)


def test_result_record_failure_rolls_back_static_and_new_ipa(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, db_calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    before = {name: (root / name).read_bytes() for name in STATIC_NAMES}
    original_write_text = Path.write_text

    def fail_result(self, data, *args, **kwargs):
        if self.name == 'result.json':
            raise OSError('result evidence unavailable')
        return original_write_text(self, data, *args, **kwargs)

    monkeypatch.setattr(Path, 'write_text', fail_result)
    with pytest.raises(OSError, match='result evidence unavailable'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert all((root / name).read_bytes() == data for name, data in before.items())
    assert not (root / urlsplit(record['artifact_url']).path.lstrip('/')).exists()
    assert [call['mode'] for call in db_calls] == ['inspect', 'inspect']


def test_existing_2173_app_update_setting_refuses_link_only_release(tmp_path, monkeypatch):
    root, source, candidate, record, settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    settings['app_ios_latest_build'] = '2173'
    with pytest.raises(ValueError, match='app update settings'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()


def test_android_setting_drift_refuses_iOS_static_release(tmp_path, monkeypatch):
    root, source, candidate, record, settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    settings['app_apk_url'] += '?concurrent=1'
    with pytest.raises(ValueError, match='app update settings'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()


def test_missing_exact_settings_baseline_refuses_release(tmp_path, monkeypatch):
    root, source, candidate, record, _settings, _calls, db, request, compare, _release = fixture(
        tmp_path, monkeypatch)
    publisher = load_module(PUBLISHER, 'ios_static_link_publisher')
    del record['expected_app_settings_before']
    with pytest.raises(ValueError, match='app update settings'):
        publisher.publish(record, root, source, candidate, tmp_path / 'backup',
                          request=request, db=db,
                          inspector=lambda _path, _record: record['ios_ipa_evidence'],
                          comparator=compare)
    assert not (tmp_path / 'backup').exists()
