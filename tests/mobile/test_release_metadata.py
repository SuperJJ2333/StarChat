import importlib.util
import hashlib
from pathlib import Path
import plistlib
from urllib.parse import urlsplit

import pytest

SPEC = importlib.util.spec_from_file_location('release_metadata', Path(__file__).parents[2] / 'scripts/release_metadata.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def release(platform='ios'):
    result = dict(platform=platform, version='0.3.102', build=2144,
                  artifact_url=f'{m.BASE}/downloads/ChatFlow-0.3.102-build2144.{"ipa" if platform == "ios" else "apk"}',
                  artifact_bytes=44218488, signing_confirmed_by='release-owner',
                  bundle_id='com.liuhetong.liuhetongMobile')
    if platform == 'ios':
        result['ios_ci_candidate_sha256'] = '0' * 64
        app_id = 'ZXB3TS7QD4.' + result['bundle_id']
        result['ios_upgrade_from'] = {
            'team_id': 'ZXB3TS7QD4',
            'application_identifier': app_id,
            'keychain_access_groups': [app_id],
            'version': '0.3.101',
            'build': 2143,
        }
    return result


def add_ios_ipa_evidence(root, r):
    """A small local stand-in for the uploaded IPA; no Apple tooling needed."""
    artifact = root / urlsplit(r['artifact_url']).path.lstrip('/')
    artifact.parent.mkdir(parents=True, exist_ok=True)
    artifact.write_bytes(b'fake-enterprise-ipa-A')
    candidate_path(root).write_bytes(b'fake-ci-candidate-A')
    r['ios_ci_candidate_sha256'] = hashlib.sha256(candidate_path(root).read_bytes()).hexdigest()
    r['artifact_bytes'] = artifact.stat().st_size
    app_id = 'ZXB3TS7QD4.' + r['bundle_id']
    r['ios_ipa_evidence'] = {
        'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
        'artifact_bytes': artifact.stat().st_size,
        'bundle_id': r['bundle_id'],
        'version': r['version'],
        'build': r['build'],
        'team_id': 'ZXB3TS7QD4',
        'profile_application_identifier': app_id,
        'signed_application_identifier': app_id,
        'aps_environment': 'production',
        'get_task_allow': False,
        'provisions_all_devices': True,
        'profile_keychain_access_groups': [app_id],
        'signed_keychain_access_groups': [app_id],
    }
    r['ios_upgrade_test'] = {
        'candidate_sha256': r['ios_ipa_evidence']['sha256'],
        'old_version': r['ios_upgrade_from']['version'],
        'old_build': r['ios_upgrade_from']['build'],
        'performed_at': '2026-09-24T10:00:00+08:00',
        'performed_by': 'release-owner',
        'installed_without_uninstall': True,
        'pre_upgrade_healthy': True,
        'chat_history_preserved': True,
        'login_preserved': True,
        'keychain_preserved': True,
        'background_notifications_confirmed': True,
    }
    return artifact


def candidate_path(root):
    return root.parent / 'ci-candidate.ipa'


def fake_payload_comparator(r):
    """Only release orchestration is mocked; comparator byte parsing has its own tests."""
    return lambda _candidate, _final: {
        'candidate_sha256': r['ios_ci_candidate_sha256'],
        'final_sha256': r['ios_ipa_evidence']['sha256'],
        'status': 'pass',
        'differences': [],
        'payload_path_count': 1,
        'final_payload_path_count': 1,
    }


def fake_ipa_inspector(r):
    """Keep metadata unit tests independent of real CMS/Mach-O fixture bytes."""
    return lambda _path: dict(r.get('ios_ipa_evidence') or {})


def test_publish_rejects_forged_evidence_for_uploaded_non_ipa_before_any_write(
        tmp_path, monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path / 'frontend'
    root.mkdir()
    (root / 'src').mkdir()
    source = Path(__file__).parents[2] / 'frontend'
    for name in ['download.html', 'src/admin-home.js']:
        (root / name).write_bytes((source / name).read_bytes())
    r = release()
    add_ios_ipa_evidence(root, r)  # Hash and metadata agree with the record, but bytes are not an IPA.
    writes = []
    real_atomic_write = m.atomic_write

    def track_static_write(path, data):
        writes.append(path)
        real_atomic_write(path, data)

    monkeypatch.setattr(m, 'atomic_write', track_static_write)
    db_calls = []

    def db(payload):
        db_calls.append(payload['mode'])
        return {'app_ios_latest_build': '2143'}

    def request(url, method='GET'):
        if method == 'HEAD':
            return {'Content-Length': str(r['artifact_bytes'])}, b''
        raise AssertionError('Public metadata was read before final IPA inspection')

    with pytest.raises(ValueError, match='IPA|archive|signature|inspect|plist|Mach-O'):
        m.publish(r, root, tmp_path / 'backup', request, db)
    assert writes == []
    assert db_calls == []
    assert not (tmp_path / 'backup').exists()


@pytest.mark.parametrize('problem', [
    'missing', 'other-candidate', 'other-old-version', 'other-old-build',
    'uninstall', 'history-lost', 'login-lost', 'missing-operator', 'naive-time',
])
def test_ios_release_requires_device_cover_install_attestation_for_exact_candidate(
        tmp_path, problem):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    attestation = r['ios_upgrade_test']
    if problem == 'missing':
        del r['ios_upgrade_test']
    elif problem == 'other-candidate':
        attestation['candidate_sha256'] = '0' * 64
    elif problem == 'other-old-version':
        attestation['old_version'] = '0.3.100'
    elif problem == 'other-old-build':
        attestation['old_build'] = 2142
    elif problem == 'uninstall':
        attestation['installed_without_uninstall'] = False
    elif problem == 'history-lost':
        attestation['chat_history_preserved'] = False
    elif problem == 'missing-operator':
        attestation['performed_by'] = None
    elif problem == 'naive-time':
        attestation['performed_at'] = '2026-09-24T10:00:00'
    else:
        attestation['login_preserved'] = False
    with pytest.raises(ValueError, match='upgrade|install|device|candidate|history|login'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_ios_release_evidence_requires_matching_local_ipa_and_signing(tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    artifact = add_ios_ipa_evidence(root, r)
    m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))

    artifact.write_bytes(b'fake-enterprise-ipa-B')  # same size, different SHA
    with pytest.raises(ValueError, match='SHA|sha256|hash'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_ios_release_rejects_inspector_result_different_from_record(tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    artifact = add_ios_ipa_evidence(root, r)
    inspected = dict(r['ios_ipa_evidence'])
    inspected['profile_keychain_access_groups'] = [
        *inspected['profile_keychain_access_groups'], 'com.apple.token']
    seen = []

    def inspect(path):
        seen.append(path)
        return inspected

    with pytest.raises(ValueError, match='inspection|evidence'):
        m.verify_ios_release_evidence(r, root, inspector=inspect)
    assert seen == [artifact.resolve()]


def test_ios_release_evidence_rejects_evidence_size_mismatch(tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_ipa_evidence']['artifact_bytes'] += 1

    with pytest.raises(ValueError, match='size|bytes'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


@pytest.mark.parametrize('field', [
    'bundle_id', 'profile_application_identifier',
    'signed_application_identifier', 'team_id',
])
def test_ios_release_evidence_rejects_mismatched_identity(tmp_path, field):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_ipa_evidence'][field] = 'ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider'
    with pytest.raises(ValueError, match='identity|identifier|bundle|team'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_ios_release_evidence_requires_production_apns_unless_explicitly_waived(tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_ipa_evidence']['aps_environment'] = None
    with pytest.raises(ValueError, match='APNs|aps'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))
    r['ios_allow_no_apns'] = True
    m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


@pytest.mark.parametrize(('field', 'invalid'), [
    ('version', '0.3.101'),
    ('build', 2143),
    ('get_task_allow', True),
    ('provisions_all_devices', False),
])
def test_ios_release_evidence_rejects_wrong_version_or_non_enterprise_signing(
        tmp_path, field, invalid):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_ipa_evidence'][field] = invalid
    with pytest.raises(ValueError):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


@pytest.mark.parametrize(('field', 'invalid'), [
    ('profile_keychain_access_groups', []),
    ('signed_keychain_access_groups', []),
    ('profile_keychain_access_groups', ['OTHERTEAM.example']),
    ('signed_keychain_access_groups', ['OTHERTEAM.example']),
])
def test_ios_release_evidence_requires_team_keychain_groups(
        tmp_path, field, invalid):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_ipa_evidence'][field] = invalid
    with pytest.raises(ValueError):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_ios_release_evidence_allows_other_enterprise_team_with_matching_upgrade_baseline(
        tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    team_id = 'ABCD123456'
    app_id = team_id + '.' + r['bundle_id']
    r['ios_ipa_evidence'].update({
        'team_id': team_id,
        'profile_application_identifier': app_id,
        'signed_application_identifier': app_id,
        'profile_keychain_access_groups': [
            team_id + '.*', 'com.apple.token', team_id + '.shared'],
        'signed_keychain_access_groups': [
            team_id + '.*', 'com.apple.token', team_id + '.shared'],
    })
    r['ios_upgrade_from'] = {
        'team_id': team_id,
        'application_identifier': app_id,
        'keychain_access_groups': [team_id + '.*', 'com.apple.token'],
        'version': '0.3.101',
        'build': 2143,
    }
    m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_ios_release_accepts_exact_legacy_signed_app_id_only_with_cover_evidence(
        tmp_path):
    root = tmp_path / 'frontend'
    r = release()
    r.update(version='0.4.7', build=2173,
             artifact_url=f'{m.BASE}/downloads/ChatFlow-0.4.7-build2173.ipa')
    add_ios_ipa_evidence(root, r)
    legacy = 'ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext'
    r['ios_upgrade_from'].update(application_identifier=legacy,
                                 version='0.3.102', build=2144)
    r['ios_ipa_evidence'].update(profile_application_identifier=legacy,
                                 signed_application_identifier=legacy)
    r['ios_upgrade_test'].update(old_version='0.3.102', old_build=2144)

    with pytest.raises(ValueError, match='identity|identifier'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))

    r['ios_legacy_application_identifier'] = legacy
    m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))

    r['ios_upgrade_test']['installed_without_uninstall'] = False
    with pytest.raises(ValueError, match='upgrade|install|device'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_legacy_identity_recovery_release_cannot_waive_production_apns():
    r = release()
    r['ios_legacy_application_identifier'] = m.LEGACY_IOS_APP_ID
    r['ios_allow_no_apns'] = True
    with pytest.raises(ValueError, match='APNs|push|notification'):
        m.validate(r)


@pytest.mark.parametrize('missing_proof', [
    'pre_upgrade_healthy', 'keychain_preserved',
    'background_notifications_confirmed',
])
def test_ios_release_requires_healthy_device_keychain_and_background_proof(
        tmp_path, missing_proof):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    r['ios_upgrade_test'].update({
        'pre_upgrade_healthy': True,
        'keychain_preserved': True,
        'background_notifications_confirmed': True,
    })
    r['ios_upgrade_test'][missing_proof] = False

    with pytest.raises(ValueError, match='upgrade|install|device|Keychain|notification'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


@pytest.mark.parametrize('team_id', [
    'ABCD12345', 'ABCD1234567', 'abcd123456', 'ABCD-23456',
])
def test_ios_release_evidence_rejects_invalid_enterprise_team_id(
        tmp_path, team_id):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    app_id = team_id + '.' + r['bundle_id']
    r['ios_ipa_evidence'].update({
        'team_id': team_id,
        'profile_application_identifier': app_id,
        'signed_application_identifier': app_id,
        'profile_keychain_access_groups': [app_id],
        'signed_keychain_access_groups': [app_id],
    })
    r['ios_upgrade_from'] = {
        'team_id': team_id,
        'application_identifier': app_id,
        'keychain_access_groups': [app_id],
        'version': '0.3.101',
        'build': 2143,
    }
    with pytest.raises(ValueError, match='team|identity|identifier'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


@pytest.mark.parametrize('problem', [
    'missing-baseline',
    'other-team',
    'other-signed-app-id',
    'dropped-old-keychain-group',
    'changed-default-keychain-group',
])
def test_ios_release_evidence_rejects_upgrade_that_cannot_preserve_app_data(
        tmp_path, problem):
    root = tmp_path / 'frontend'
    r = release()
    add_ios_ipa_evidence(root, r)
    evidence = r['ios_ipa_evidence']
    baseline = r['ios_upgrade_from']
    if problem == 'missing-baseline':
        del r['ios_upgrade_from']
    elif problem == 'other-team':
        baseline['team_id'] = 'ABCD123456'
        baseline['application_identifier'] = 'ABCD123456.' + r['bundle_id']
        baseline['keychain_access_groups'] = [baseline['application_identifier']]
    elif problem == 'other-signed-app-id':
        baseline['application_identifier'] = 'ZXB3TS7QD4.other.application'
    elif problem == 'dropped-old-keychain-group':
        baseline['keychain_access_groups'].append('ZXB3TS7QD4.shared')
    else:
        evidence['profile_keychain_access_groups'] = [
            'ZXB3TS7QD4.shared', evidence['profile_keychain_access_groups'][0]]
        evidence['signed_keychain_access_groups'] = [
            'ZXB3TS7QD4.shared', evidence['signed_keychain_access_groups'][0]]
    with pytest.raises(ValueError, match='upgrade|baseline|team|identity|keychain'):
        m.verify_ios_release_evidence(r, root, inspector=fake_ipa_inspector(r))


def test_android_release_does_not_require_ios_ipa_evidence(tmp_path):
    m.verify_ios_release_evidence(release('android'), tmp_path)


def test_manifest_roundtrip_and_settings_platform_isolation():
    r = release()
    d = plistlib.loads(m.manifest(r))
    assert d['items'][0]['metadata']['bundle-version'] == '2144'
    assert d['items'][0]['assets'][0]['url'] == r['artifact_url']
    assert m.settings(r)['app_ios_download_url'] == m.INSTALL
    assert all(k.startswith('app_ios_') for k in m.settings(r))
    assert set(m.settings(release('android'))) == {'app_latest_version', 'app_latest_build', 'app_apk_url'}


@pytest.mark.parametrize('change', [dict(platform='other'), dict(version='x'), dict(build=0),
    dict(artifact_url='http://example.com/a.ipa'), dict(artifact_bytes=0),
    dict(signing_confirmed_by=''), dict(artifact_url=m.BASE+'/downloads/../a.ipa')])
def test_invalid_release_fails_closed(change):
    r = release(); r.update(change)
    with pytest.raises(ValueError): m.validate(r)


def test_render_updates_all_ios_metadata_and_preserves_android():
    root = Path(__file__).parents[2] / 'frontend'
    r = release(); r.update(version='0.3.103', build=2145)
    output = m.render(r, (root/'download.html').read_bytes(), (root/'src/admin-home.js').read_bytes())
    assert '0.3.103（2145）'.encode() in output['download.html']
    assert '0.3.103（2145）'.encode() in output['src/admin-home.js']
    assert b'/downloads/latest-arm64.apk' in output['download.html']
    assert b'0.3.102' not in output['src/admin-home.js']


def test_check_rejects_broken_xml_and_never_gets_artifact():
    r = release(); calls = []
    def fetch(url, method='GET'):
        calls.append((url, method))
        if method == 'HEAD': return {'Content-Length':str(r['artifact_bytes'])}, b''
        return {}, b'<plist><dict>'
    with pytest.raises(Exception): m.check(r, fetch)
    assert (r['artifact_url'], 'HEAD') in calls
    assert (r['artifact_url'], 'GET') not in calls


def test_check_rejects_wrong_content_length():
    with pytest.raises(ValueError, match='length'):
        m.check(release('android'), lambda *a, **k: ({'Content-Length':'1'}, b''))


def test_valid_remote_metadata_uses_head_only_for_binary():
    r = release(); root = Path(__file__).parents[2] / 'frontend'
    output = m.render(r, (root/'download.html').read_bytes(), (root/'src/admin-home.js').read_bytes())
    calls = []
    def request(url, method='GET'):
        calls.append((url, method))
        if method == 'HEAD': return {'Content-Length': str(r['artifact_bytes'])}, b''
        path = {'/download':'download.html', '/src/admin-home.js':'src/admin-home.js',
                '/downloads/ios/manifest.plist':'downloads/ios/manifest.plist'}[url.removeprefix(m.BASE)]
        return {'Content-Type':'application/xml', 'Cache-Control':'no-store'}, output[path]
    m.check(r, request)
    assert calls[0] == (r['artifact_url'], 'HEAD')
    assert len(calls) == 4


def test_publish_restores_pages_when_remote_verification_fails(tmp_path, monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path/'frontend'; root.mkdir(); (root/'src').mkdir();(root/'downloads/ios').mkdir(parents=True)
    source = Path(__file__).parents[2]/'frontend'
    for name in ['download.html','src/admin-home.js']:
        (root/name).write_bytes((source/name).read_bytes())
    r = release()
    add_ios_ipa_evidence(root, r)
    old = (root/'download.html').read_bytes()
    (root/'downloads/ios/manifest.plist').write_bytes(b'old')
    calls = []
    def db(payload):
        calls.append(payload['mode']); return {'app_ios_latest_build':'2143'}
    def request(url, method='GET'):
        if method=='HEAD': return {'Content-Length':str(r['artifact_bytes'])},b''
        return {},b'<plist>'
    with pytest.raises(Exception): m.publish(
        r, root, tmp_path/'backup', request, db, inspector=fake_ipa_inspector(r),
        candidate=candidate_path(root), comparator=fake_payload_comparator(r))
    assert (root/'download.html').read_bytes() == old
    assert (root/'downloads/ios/manifest.plist').read_bytes() == b'old'
    assert calls == ['inspect']  # No popup published before static gates pass.


def test_publish_calls_settings_only_after_public_checks(tmp_path, monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path/'frontend';(root/'src').mkdir(parents=True)
    source = Path(__file__).parents[2]/'frontend'
    for name in ['download.html','src/admin-home.js']:
        (root/name).write_bytes((source/name).read_bytes())
    r = release()
    add_ios_ipa_evidence(root, r)
    before = {'app_ios_latest_build':'2143', 'app_latest_build':'2140', 'app_ios_min_supported_build':'3'}
    checks = []
    def request(url, method='GET'):
        checks.append((url, method))
        if method=='HEAD': return {'Content-Length':str(r['artifact_bytes'])},b''
        path = 'download.html' if url == m.BASE+'/download' else url.removeprefix(m.BASE+'/')
        return {'Content-Type':'application/xml', 'Cache-Control':'no-store'}, (root/path).read_bytes()
    def db(payload):
        if payload['mode']=='inspect': return before
        assert len(checks) == 5
        assert payload['expected'] == before
        assert payload['values'] == m.settings(r)
        return before | payload['values']
    m.publish(r, root, tmp_path/'backup', request, db,
              inspector=fake_ipa_inspector(r), candidate=candidate_path(root),
              comparator=fake_payload_comparator(r))
    assert (tmp_path/'backup/after.json').exists()
    comparison = (tmp_path/'backup/ios-payload-comparison.json').read_text(encoding='utf-8')
    assert r['ios_ci_candidate_sha256'] in comparison
    assert r['ios_ipa_evidence']['sha256'] in comparison


def test_publish_rechecks_ipa_sha_after_public_checks_before_setting_write(
        tmp_path, monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path / 'frontend'
    (root / 'src').mkdir(parents=True)
    (root / 'downloads/ios').mkdir(parents=True)
    source = Path(__file__).parents[2] / 'frontend'
    for name in ['download.html', 'src/admin-home.js']:
        (root / name).write_bytes((source / name).read_bytes())
    before_page = (root / 'download.html').read_bytes()
    before_home = (root / 'src/admin-home.js').read_bytes()
    before_manifest = b'old manifest'
    (root / 'downloads/ios/manifest.plist').write_bytes(before_manifest)
    r = release()
    artifact = add_ios_ipa_evidence(root, r)
    modes = []
    swapped = False

    def request(url, method='GET'):
        nonlocal swapped
        if method == 'HEAD':
            return {'Content-Length': str(r['artifact_bytes'])}, b''
        if url == m.MANIFEST and not swapped:
            swapped = True
            artifact.write_bytes(b'fake-enterprise-ipa-B')
            assert artifact.stat().st_size == r['artifact_bytes']
        path = {'/download': 'download.html',
                '/src/admin-home.js': 'src/admin-home.js',
                '/downloads/ios/manifest.plist': 'downloads/ios/manifest.plist'}[
                    url.removeprefix(m.BASE)]
        return {'Content-Type': 'application/xml', 'Cache-Control': 'no-store'}, (
            root / path).read_bytes()

    before_settings = {
        'app_ios_latest_build': '2143',
        'app_latest_build': '2140',
        'app_ios_min_supported_build': '3',
    }

    def db(payload):
        modes.append(payload['mode'])
        return before_settings if payload['mode'] == 'inspect' else (
            before_settings | payload['values'])

    with pytest.raises(ValueError, match='SHA|sha256|hash'):
        m.publish(r, root, tmp_path / 'backup', request, db,
                  inspector=fake_ipa_inspector(r), candidate=candidate_path(root),
                  comparator=fake_payload_comparator(r))
    assert swapped
    assert modes == ['inspect']
    assert (root / 'download.html').read_bytes() == before_page
    assert (root / 'src/admin-home.js').read_bytes() == before_home
    assert (root / 'downloads/ios/manifest.plist').read_bytes() == before_manifest


@pytest.mark.parametrize('problem', [
    'missing', 'wrong-app-id', 'wrong-sha', 'missing-upgrade-baseline',
    'cross-team-upgrade', 'dropped-old-keychain-group',
    'changed-default-keychain-group',
])
def test_publish_rejects_unverified_ios_ipa_before_static_or_db_write(
        tmp_path, monkeypatch, problem):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path / 'frontend'
    (root / 'src').mkdir(parents=True)
    source = Path(__file__).parents[2] / 'frontend'
    for name in ['download.html', 'src/admin-home.js']:
        (root / name).write_bytes((source / name).read_bytes())
    old_page = (root / 'download.html').read_bytes()
    writes = []
    real_atomic_write = m.atomic_write

    def track_static_write(path, data):
        writes.append(path)
        real_atomic_write(path, data)

    monkeypatch.setattr(m, 'atomic_write', track_static_write)
    r = release()
    if problem != 'missing':
        artifact = add_ios_ipa_evidence(root, r)
        if problem == 'wrong-app-id':
            r['ios_ipa_evidence']['signed_application_identifier'] = (
                'ZXB3TS7QD4.cn.edu.buaa.bhpan.fileProvider')
        elif problem == 'wrong-sha':
            artifact.write_bytes(b'fake-enterprise-ipa-B')
        elif problem == 'missing-upgrade-baseline':
            del r['ios_upgrade_from']
        elif problem == 'cross-team-upgrade':
            r['ios_upgrade_from']['team_id'] = 'ABCD123456'
            r['ios_upgrade_from']['application_identifier'] = (
                'ABCD123456.' + r['bundle_id'])
            r['ios_upgrade_from']['keychain_access_groups'] = [
                r['ios_upgrade_from']['application_identifier']]
        elif problem == 'dropped-old-keychain-group':
            r['ios_upgrade_from']['keychain_access_groups'].append(
                'ZXB3TS7QD4.shared')
        elif problem == 'changed-default-keychain-group':
            original = r['ios_ipa_evidence']['signed_keychain_access_groups'][0]
            r['ios_ipa_evidence']['signed_keychain_access_groups'] = [
                'ZXB3TS7QD4.shared', original]
            r['ios_ipa_evidence']['profile_keychain_access_groups'] = [
                'ZXB3TS7QD4.shared', original]
    calls = []

    def request(url, method='GET'):
        calls.append(('remote', url, method))
        return {'Content-Length': str(r['artifact_bytes'])}, b''

    def db(payload):
        calls.append(('db', payload['mode']))
        return {'app_ios_latest_build': '2143'}

    with pytest.raises(ValueError):
        m.publish(r, root, tmp_path / 'backup', request, db,
                  inspector=fake_ipa_inspector(r))
    assert writes == []
    assert ('db', 'apply') not in calls
    assert (root / 'download.html').read_bytes() == old_page
    assert not (root / 'downloads/ios/manifest.plist').exists()


@pytest.mark.parametrize('invalid', [None, '', 'A' * 64, '0' * 63])
def test_ios_release_record_requires_ci_candidate_sha256(invalid):
    r = release()
    if invalid is None:
        del r['ios_ci_candidate_sha256']
    else:
        r['ios_ci_candidate_sha256'] = invalid
    with pytest.raises(ValueError, match='CI candidate|SHA256'):
        m.validate(r)


@pytest.mark.parametrize('problem', [
    'missing-ci-ipa', 'candidate-sha-mismatch', 'candidate-bytes-replaced',
    'payload-change', 'reported-final-sha-mismatch', 'same-final-ipa',
    'empty-inventory-report', 'changed-during-comparison',
])
def test_publish_rejects_unmatched_ci_payload_before_any_write(
        tmp_path, monkeypatch, problem):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path / 'frontend'
    (root / 'src').mkdir(parents=True)
    source = Path(__file__).parents[2] / 'frontend'
    for name in ['download.html', 'src/admin-home.js']:
        (root / name).write_bytes((source / name).read_bytes())
    r = release()
    final = add_ios_ipa_evidence(root, r)
    candidate = candidate_path(root)
    if problem == 'missing-ci-ipa':
        candidate = None
    elif problem == 'candidate-sha-mismatch':
        r['ios_ci_candidate_sha256'] = '1' * 64
    elif problem == 'candidate-bytes-replaced':
        candidate.write_bytes(b'fake-ci-candidate-B')
    elif problem == 'same-final-ipa':
        candidate = final
        r['ios_ci_candidate_sha256'] = r['ios_ipa_evidence']['sha256']

    def compare(first, second):
        report = fake_payload_comparator(r)(first, second)
        if problem == 'payload-change':
            report.update(status='fail', differences=['added Payload path: injected.dylib'])
        elif problem == 'reported-final-sha-mismatch':
            report['final_sha256'] = '2' * 64
        elif problem == 'empty-inventory-report':
            report['payload_path_count'] = 0
        elif problem == 'changed-during-comparison':
            candidate.write_bytes(b'fake-ci-candidate-B')
        return report

    writes = []
    real_atomic_write = m.atomic_write

    def track_static_write(path, data):
        writes.append(path)
        real_atomic_write(path, data)

    monkeypatch.setattr(m, 'atomic_write', track_static_write)
    db_calls = []

    def db(payload):
        db_calls.append(payload['mode'])
        raise AssertionError('DB inspected before the IPA payload gate')

    def request(url, method='GET'):
        raise AssertionError('public metadata read before the IPA payload gate')

    with pytest.raises(ValueError, match='CI candidate|SHA|payload|compare'):
        m.publish(r, root, tmp_path / 'backup', request, db,
                  inspector=fake_ipa_inspector(r), candidate=candidate,
                  comparator=compare)
    assert writes == []
    assert db_calls == []
    assert not (tmp_path / 'backup').exists()


def test_publish_rechecks_ci_payload_after_public_checks_and_restores_static(
        tmp_path, monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(
        LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root = tmp_path / 'frontend'
    (root / 'src').mkdir(parents=True)
    (root / 'downloads/ios').mkdir(parents=True)
    source = Path(__file__).parents[2] / 'frontend'
    for name in ['download.html', 'src/admin-home.js']:
        (root / name).write_bytes((source / name).read_bytes())
    before_page = (root / 'download.html').read_bytes()
    before_home = (root / 'src/admin-home.js').read_bytes()
    (root / 'downloads/ios/manifest.plist').write_bytes(b'old manifest')
    r = release()
    add_ios_ipa_evidence(root, r)
    comparisons = []

    def compare(first, second):
        comparisons.append((first, second))
        report = fake_payload_comparator(r)(first, second)
        if len(comparisons) == 2:
            report.update(status='fail', differences=['Mach-O code changed'])
        return report

    def request(url, method='GET'):
        if method == 'HEAD':
            return {'Content-Length': str(r['artifact_bytes'])}, b''
        path = {'/download': 'download.html',
                '/src/admin-home.js': 'src/admin-home.js',
                '/downloads/ios/manifest.plist': 'downloads/ios/manifest.plist'}[
                    url.removeprefix(m.BASE)]
        return {'Content-Type': 'application/xml', 'Cache-Control': 'no-store'}, (
            root / path).read_bytes()

    db_calls = []

    def db(payload):
        db_calls.append(payload['mode'])
        return {'app_ios_latest_build': '2143'}

    with pytest.raises(ValueError, match='payload|compare'):
        m.publish(r, root, tmp_path / 'backup', request, db,
                  inspector=fake_ipa_inspector(r), candidate=candidate_path(root),
                  comparator=compare)
    assert len(comparisons) == 2
    assert db_calls == ['inspect']
    assert (root / 'download.html').read_bytes() == before_page
    assert (root / 'src/admin-home.js').read_bytes() == before_home
    assert (root / 'downloads/ios/manifest.plist').read_bytes() == b'old manifest'
