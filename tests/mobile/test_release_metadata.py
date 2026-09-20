import importlib.util
from pathlib import Path
import plistlib

import pytest

SPEC = importlib.util.spec_from_file_location('release_metadata', Path(__file__).parents[2] / 'scripts/release_metadata.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def release(platform='ios'):
    return dict(platform=platform, version='0.3.102', build=2144,
                artifact_url=f'{m.BASE}/downloads/ChatFlow-0.3.102-build2144.{"ipa" if platform == "ios" else "apk"}',
                artifact_bytes=44218488, signing_confirmed_by='release-owner',
                bundle_id='com.liuhetong.liuhetongMobile')


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
    old = (root/'download.html').read_bytes()
    (root/'downloads/ios/manifest.plist').write_bytes(b'old')
    calls = []
    def db(payload):
        calls.append(payload['mode']); return {'app_ios_latest_build':'2143'}
    def request(url, method='GET'):
        if method=='HEAD': return {'Content-Length':'44218488'},b''
        return {},b'<plist>'
    with pytest.raises(Exception): m.publish(release(), root, tmp_path/'backup', request, db)
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
    before = {'app_ios_latest_build':'2143', 'app_latest_build':'2140', 'app_ios_min_supported_build':'3'}
    checks = []
    def request(url, method='GET'):
        checks.append((url, method))
        if method=='HEAD': return {'Content-Length':'44218488'},b''
        path = 'download.html' if url == m.BASE+'/download' else url.removeprefix(m.BASE+'/')
        return {'Content-Type':'application/xml', 'Cache-Control':'no-store'}, (root/path).read_bytes()
    def db(payload):
        if payload['mode']=='inspect': return before
        assert len(checks) == 5
        assert payload['expected'] == before
        assert payload['values'] == m.settings(release())
        return before | payload['values']
    m.publish(release(), root, tmp_path/'backup', request, db)
    assert (tmp_path/'backup/after.json').exists()
