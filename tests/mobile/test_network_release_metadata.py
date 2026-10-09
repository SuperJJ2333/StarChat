import importlib.util
from pathlib import Path

import pytest


SPEC = importlib.util.spec_from_file_location('network_release_metadata', Path(__file__).parents[2] / 'scripts/release_metadata.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def ios_panel(page):
    # Orbit's iOS tab ends at the surrounding device section. Preserve the
    # whole block, including installation instructions and enterprise warning.
    marker = b'<div id="ios-panel"'
    assert page.count(marker) == 1
    panel = page.split(marker, 1)[1]
    assert b'</section>' in panel
    return marker + panel.split(b'</section>', 1)[0]


def release(**changes):
    import hashlib
    names=('download-redirect.js','download-network.js','download-network-selector.js')
    asset_hashes={name:hashlib.sha256((Path(__file__).parents[2]/'frontend/src'/name).read_bytes()).hexdigest() for name in names}
    return dict(platform='android', version='0.4.19', build=2188,
                artifact_url=m.BASE + '/downloads/ChatFlow-0.4.19-build2188-arm64.apk',
                artifact_bytes=81505310, signing_confirmed_by='existing-fixed-signer-handoff',
                cdn_url='https://dexamplenetwork.cloudfront.net/downloads/ChatFlow-0.4.19-build2188-arm64.apk',
                artifact_sha256='aa402236aa2dbf06c5322358c6f8ad66e50f06ab5487bc08871ae34934d5e220',
                network_assets=asset_hashes,
                **changes)


def test_opted_in_android_popup_uses_network_selection_page():
    record = release(network_selection=True)
    assert m.settings(record) == {'app_apk_url': m.BASE + '/download?platform=android&install=1'}


@pytest.mark.parametrize('version,build', [('0.4.18','2188'), ('0.4.19','2187'), (None,'2188')])
def test_network_publish_refuses_new_version_before_static_write(tmp_path, monkeypatch, version, build):
    import sys
    import types
    monkeypatch.setitem(sys.modules, 'fcntl', types.SimpleNamespace(LOCK_EX=1, LOCK_NB=2, flock=lambda *a: None))
    root=tmp_path/'frontend'; (root/'src').mkdir(parents=True)
    source=Path(__file__).parents[2]/'frontend'
    for name in ['download.html','src/admin-home.js']:
        (root/name).write_bytes((source/name).read_bytes())
    original=(root/'download.html').read_bytes(); calls=[]
    def db(payload):
        calls.append(payload['mode'])
        return {'app_latest_version':version,'app_latest_build':build}
    def request(url,method='GET'):
        assert method=='HEAD', 'public static checks must not run after version mismatch'
        return {'Content-Length':'81505310'},b''
    with pytest.raises(ValueError,match='existing release'):
        m.publish(release(network_selection=True),root,tmp_path/'backup',request,db)
    assert calls==['inspect']
    assert (root/'download.html').read_bytes()==original
    assert not (root/'downloads/android-release.json').exists()


def test_legacy_android_release_stays_on_immutable_artifact():
    record = release()
    assert m.settings(record)['app_apk_url'] == record['artifact_url']


@pytest.mark.parametrize('value', ['true', 1, None, {}, []])
def test_network_option_has_strict_type(value):
    with pytest.raises(ValueError, match='network'):
        m.validate(release(network_selection=value))


def test_network_option_does_not_change_ios_installation():
    record = release(network_selection=True)
    record.update(platform='ios', artifact_url=m.BASE + '/downloads/ChatFlow-0.4.7-build2173-ios.ipa',
                  bundle_id=m.BUNDLE)
    with pytest.raises(ValueError, match='network'):
        m.validate(record)


@pytest.mark.parametrize('field,value', [
    ('cdn_url','https://evil.invalid/downloads/ChatFlow-0.4.19-build2188-arm64.apk'),
    ('cdn_url','https://dother.cloudfront.net/downloads/latest-arm64.apk'),
    ('cdn_url','https://dother.cloudfront.net/downloads/ChatFlow-0.4.16-build2185-arm64.apk'),
    ('artifact_sha256','broken'),
])
def test_network_requires_pinned_same_version_and_hash(field,value):
    record=release(network_selection=True);record[field]=value
    with pytest.raises(ValueError,match='network'):
        m.validate(record)


def test_network_check_refuses_popup_before_selector_registry_exists():
    record=release(network_selection=True)
    def request(url,method='GET'):
        if method=='HEAD': return {'Content-Length':'81505310'},b''
        return {'Content-Type':'text/html'},b'<html>old page</html>'
    with pytest.raises(ValueError,match='network'):
        m.check(record,request)


def test_network_check_checks_same_release_metadata_without_binary_get():
    import json
    from urllib.parse import urlsplit
    record=release(network_selection=True);calls=[]
    registry=dict(platform='android',version=record['version'],build=record['build'],
                  artifact_bytes=record['artifact_bytes'],sha256=record['artifact_sha256'],
                  direct_url=record['artifact_url'],cdn_url=record['cdn_url'])
    host=urlsplit(record['cdn_url']).hostname
    def request(url,method='GET'):
        calls.append((url,method))
        if method=='HEAD':return {'Content-Length':'81505310','Content-Type':'application/vnd.android.package-archive'},b''
        if url.endswith('/downloads/android-release.json'):
            return {'Content-Type':'application/json','Cache-Control':'no-store'},json.dumps(registry).encode()
        if url==m.BASE+'/download?platform=android&install=1':
            return {'Content-Type':'text/html'},f'<a id="android-network-download" data-cdn-host="{host}"></a><a id="android-direct-download"></a>'.encode()
        if url.startswith(m.BASE+'/src/'):
            return {'Content-Type':'text/javascript'},(Path(__file__).parents[2]/'frontend/src'/url.rsplit('/',1)[1]).read_bytes()
        raise AssertionError(url)
    m.check(record,request)
    assert (record['artifact_url'],'GET') not in calls
    assert (record['cdn_url'],'GET') not in calls
    assert (record['cdn_url'],'HEAD') in calls


def test_network_render_keeps_ios_and_business_ui_and_is_repeatable():
    import json
    root=Path(__file__).parents[2]/'frontend'
    page=(root/'download.html').read_bytes();home=(root/'src/admin-home.js').read_bytes()
    record=release(network_selection=True)
    staged=m.render(record,page,home)
    assert set(staged)=={'download.html','src/admin-home.js','downloads/android-release.json'}
    assert b'data-cdn-host="dexamplenetwork.cloudfront.net"' in staged['download.html']
    assert staged['download.html'].count(b'id="android-direct-download"')==1
    assert ios_panel(staged['download.html']) == ios_panel(page)
    assert staged['src/admin-home.js'].split(b'function androidApkPath')[0]==home.split(b'function androidApkPath')[0]
    registry=json.loads(staged['downloads/android-release.json'])
    assert registry['cdn_url']==record['cdn_url']
    assert registry['sha256']==record['artifact_sha256']
    assert m.render(record,staged['download.html'],staged['src/admin-home.js'])==staged


def test_render_refuses_unknown_download_page_drift():
    with pytest.raises(ValueError,match='network'):
        m.render(release(network_selection=True),b'<html>changed elsewhere</html>',b'changed elsewhere')


def test_network_gate_refuses_stale_selector_assets():
    import json
    record=release(network_selection=True)
    def request(url,method='GET'):
        if method=='HEAD':return {'Content-Length':'81505310','Content-Type':'application/octet-stream'},b''
        if url.endswith('/downloads/android-release.json'):
            return {'Content-Type':'application/json','Cache-Control':'no-store'},json.dumps(m.network_registry(record)).encode()
        if '/src/' in url:return {'Content-Type':'text/javascript'},b'old selector'
        return {},b'<a id="android-network-download" data-cdn-host="dexamplenetwork.cloudfront.net"></a><a id="android-direct-download"></a>'
    with pytest.raises(ValueError,match='network.*asset'):
        m.check(record,request)


def test_next_regular_android_release_disables_old_selector_and_refreshes_backup():
    root=Path(__file__).parents[2]/'frontend'
    page=(root/'download.html').read_bytes();home=(root/'src/admin-home.js').read_bytes()
    active=m.render(release(network_selection=True),page,home)
    next_release=release();next_release.update(version='0.4.20',build=2189,
        artifact_url=m.BASE+'/downloads/ChatFlow-0.4.20-build2189-arm64.apk')
    output=m.render(next_release,active['download.html'],active['src/admin-home.js'])
    assert set(output)=={'download.html'}
    new_page=output['download.html']
    assert b'data-cdn-host=""' in new_page
    assert b'dexamplenetwork.cloudfront.net' not in new_page
    assert b'id="android-direct-download" href="/downloads/ChatFlow-0.4.20-build2189-arm64.apk"' in new_page
    assert b'href="/downloads/latest-arm64.apk" download>\xe4\xb8\x8b\xe8\xbd\xbd Android' in new_page
    assert ios_panel(new_page) == ios_panel(active['download.html'])
    assert '/download?platform=android&install=1' in active['src/admin-home.js'].decode()
    newer=next_release|{'version':'0.4.21','build':2190,
        'artifact_url':m.BASE+'/downloads/ChatFlow-0.4.21-build2190-arm64.apk'}
    assert b'id="android-direct-download" href="/downloads/ChatFlow-0.4.21-build2190-arm64.apk"' in m.render(newer,new_page,active['src/admin-home.js'])['download.html']


def test_regular_android_old_template_still_has_no_static_changes():
    old=b'<html><a href="/downloads/latest-arm64.apk" download>Android</a></html>'
    assert m.render(release(),old,b'original homepage')=={}


def test_regular_android_refuses_partial_network_marker_drift():
    page=b'<a id="android-network-download" data-cdn-host="dexample.cloudfront.net"></a>'
    with pytest.raises(ValueError,match='network'):
        m.render(release(),page,b'original homepage')


def regular_publish_fixture(tmp_path,monkeypatch):
    import sys
    import types
    monkeypatch.setitem(sys.modules,'fcntl',types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,flock=lambda *a:None))
    source=Path(__file__).parents[2]/'frontend';root=tmp_path/'frontend';(root/'src').mkdir(parents=True)
    active=m.render(release(network_selection=True),(source/'download.html').read_bytes(),(source/'src/admin-home.js').read_bytes())
    for name in ('download.html','src/admin-home.js'):(root/name).write_bytes(active[name])
    record=release();record.update(version='0.4.20',build=2189,
        artifact_url=m.BASE+'/downloads/ChatFlow-0.4.20-build2189-arm64.apk')
    return root,record


@pytest.mark.parametrize('drift',['host','fallback','script','missing'])
def test_regular_publish_refuses_stale_public_page_and_restores_local_static(tmp_path,monkeypatch,drift):
    root,record=regular_publish_fixture(tmp_path,monkeypatch)
    original=(root/'download.html').read_bytes();calls=[];http=[]
    def request(url,method='GET'):
        http.append((url,method))
        if method=='HEAD':return {'Content-Length':'81505310'},b''
        assert url==m.BASE+'/download'
        payload=(root/'download.html').read_bytes()
        if drift=='host':payload=payload.replace(b'data-cdn-host=""',b'data-cdn-host="dold.cloudfront.net"')
        if drift=='fallback':payload=payload.replace(b'ChatFlow-0.4.20-build2189-arm64.apk',b'ChatFlow-0.4.19-build2188-arm64.apk')
        if drift=='script':payload=payload.replace(b'?v=2189-legacy',b'?v=2188-network')
        if drift=='missing':payload=b'<html>different document root</html>'
        return {'Content-Type':'text/html'},payload
    def db(payload):
        calls.append(payload['mode']);return {'app_latest_build':'2188','app_latest_version':'0.4.19'}
    with pytest.raises(ValueError,match='regular Android.*page'):
        m.publish(record,root,tmp_path/'backup',request,db)
    assert calls==['inspect']
    assert (root/'download.html').read_bytes()==original
    assert (m.BASE+'/download','GET') in http
    assert all(method=='HEAD' for url,method in http if url==record['artifact_url'])


def test_regular_publish_public_page_gate_precedes_setting_apply(tmp_path,monkeypatch):
    root,record=regular_publish_fixture(tmp_path,monkeypatch);http=[];db_calls=[]
    before={'app_latest_build':'2188','app_latest_version':'0.4.19'}
    def request(url,method='GET'):
        http.append((url,method))
        if method=='HEAD':return {'Content-Length':'81505310'},b''
        assert url==m.BASE+'/download'
        return {'Content-Type':'text/html'},(root/'download.html').read_bytes()
    def db(payload):
        db_calls.append(payload['mode'])
        if payload['mode']=='inspect':return before
        assert http[-1]==(m.BASE+'/download','GET')
        assert payload['values']==m.settings(record)
        return before|payload['values']
    m.publish(record,root,tmp_path/'backup',request,db)
    assert db_calls==['inspect','apply']
    assert all(method=='HEAD' for url,method in http if url==record['artifact_url'])


def test_regular_old_template_publish_still_checks_only_apk_head(tmp_path,monkeypatch):
    root,record=regular_publish_fixture(tmp_path,monkeypatch)
    (root/'download.html').write_bytes(b'<html>original without network markers</html>')
    http=[]
    def request(url,method='GET'):
        http.append((url,method));assert method=='HEAD'
        return {'Content-Length':'81505310'},b''
    def db(payload):
        return {'app_latest_build':'2188','app_latest_version':'0.4.19'}|payload.get('values',{})
    m.publish(record,root,tmp_path/'backup',request,db)
    assert http==[(record['artifact_url'],'HEAD')]*2
