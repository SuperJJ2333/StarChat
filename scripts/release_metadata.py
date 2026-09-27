"""Publish small release metadata. Never download or inspect APK/IPA bytes.

Run prepare/check anywhere; publish on the production host. Signing confirmation
is an operator attestation, not a claim that this script verifies signatures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.request
from urllib.parse import urlsplit

BASE = 'https://www.liuhetong888.com'
INSTALL = BASE + '/download?platform=ios&install=1'
MANIFEST = BASE + '/downloads/ios/manifest.plist'
BUNDLE = 'com.liuhetong.liuhetongMobile'


def validate(r):
    if r.get('platform') not in ('ios', 'android'):
        raise ValueError('platform must be ios or android')
    if 'network_selection' in r and (type(r['network_selection']) is not bool
            or (r['network_selection'] and r['platform'] != 'android')):
        raise ValueError('network selection is a strict Android boolean option')
    if not re.fullmatch(r'\d+\.\d+\.\d+', r.get('version', '')):
        raise ValueError('invalid version')
    for key in ('build', 'artifact_bytes'):
        if type(r.get(key)) is not int or r[key] <= 0:
            raise ValueError('invalid ' + key)
    url = urlsplit(r.get('artifact_url', ''))
    suffix = 'ipa' if r['platform'] == 'ios' else 'apk'
    if (url.scheme != 'https' or url.netloc != 'www.liuhetong888.com'
            or url.query or url.fragment
            or not re.fullmatch(r'/downloads/(?:ios/)?[A-Za-z0-9_-][A-Za-z0-9_.-]*\.' + suffix, url.path)
            or '..' in url.path):
        raise ValueError('invalid immutable artifact URL')
    if r.get('network_selection'):
        cdn = urlsplit(r.get('cdn_url', ''))
        if (cdn.scheme != 'https' or not re.fullmatch(r'd[a-z0-9]+\.cloudfront\.net', cdn.netloc)
                or cdn.path != url.path or cdn.query or cdn.fragment
                or not re.fullmatch(r'/downloads/ChatFlow-' + re.escape(r['version'])
                    + '-build' + str(r['build']) + r'-arm64\.apk', url.path)
                or not re.fullmatch(r'[a-f0-9]{64}', r.get('artifact_sha256', ''))):
            raise ValueError('invalid pinned network release')
        assets = r.get('network_assets')
        if (not isinstance(assets, dict) or set(assets) != {
                'download-redirect.js', 'download-network.js', 'download-network-selector.js'}
                or any(not isinstance(value, str) or not re.fullmatch(r'[a-f0-9]{64}', value)
                       for value in assets.values())):
            raise ValueError('invalid network asset handoff')
    if not str(r.get('signing_confirmed_by', '')).strip():
        raise ValueError('final signing handoff must be confirmed by release owner')
    if r['platform'] == 'ios' and r.get('bundle_id') != BUNDLE:
        raise ValueError('bundle identity changed')


def settings(r):
    validate(r)
    if r['platform'] == 'ios':
        return {'app_ios_latest_version': r['version'], 'app_ios_latest_build': str(r['build']),
                'app_ios_download_url': INSTALL}
    if r.get('network_selection'):
        return {'app_apk_url': BASE + '/download?platform=android&install=1'}
    return {'app_latest_version': r['version'], 'app_latest_build': str(r['build']),
            'app_apk_url': r['artifact_url']}


def manifest(r):
    validate(r)
    data = plistlib.dumps({'items': [{'assets': [{'kind': 'software-package', 'url': r['artifact_url']}],
        'metadata': {'bundle-identifier': r['bundle_id'], 'bundle-version': str(r['build']),
                     'kind': 'software', 'title': '畅聊正式版'}}]}, sort_keys=False)
    plistlib.loads(data)
    return data


def render(r, page, home):
    validate(r)
    if r.get('network_selection'):
        return render_network_download(r, page, home)
    if r['platform'] != 'ios':
        return render_regular_android_download(r, page)
    label = f"{r['version']}（{r['build']}）"
    page, home = page.decode('utf-8'), home.decode('utf-8')
    page, count = re.subn(r'\d+\.\d+\.\d+（\d+） · [\d.]+ MB · iOS',
        f"{label} · {r['artifact_bytes']/1_000_000:.1f} MB · iOS", page)
    if count != 1: raise ValueError('download label drift')
    page, count = re.subn(r'(<a class="download-file" href=")[^"]+(" download>下载 IPA)',
        lambda m: m[1] + urlsplit(r['artifact_url']).path + m[2], page)
    if count != 1: raise ValueError('IPA link drift')
    # Always restore the canonical OTA link rather than copying a stale/manual
    # direct-IPA installation link from a previous deployment.
    page, count = re.subn(r'(<a class="land-btn land-btn-primary download-install" href=")[^"]+(">安装 iOS 正式版)',
        lambda m: m[1] + 'itms-services://?action=download-manifest&amp;url=' + MANIFEST + m[2], page)
    if count != 1: raise ValueError('iOS install button drift')
    home, count = re.subn(r'\d+\.\d+\.\d+（\d+）', label, home)
    if count != 3: raise ValueError('homepage label drift')
    return {'download.html': page.encode(), 'src/admin-home.js': home.encode(),
            'downloads/ios/manifest.plist': manifest(r)}


def network_registry(r):
    return {'platform': 'android', 'version': r['version'], 'build': r['build'],
            'artifact_bytes': r['artifact_bytes'], 'sha256': r['artifact_sha256'],
            'cdn_url': r['cdn_url'], 'direct_url': r['artifact_url']}


def render_regular_android_download(r, page):
    page = page.decode('utf-8')
    if ('id="android-network-download"' not in page
            and 'id="android-direct-download"' not in page):
        return {}  # Original Android templates need no static release change.
    if (page.count('id="android-network-download"') != 1
            or page.count('id="android-direct-download"') != 1
            or not re.search(r'id="android-network-download"[^>]*href="/downloads/latest-arm64\.apk"[^>]* download', page)):
        raise ValueError('network Android native link drift')
    page, count = re.subn(r'(id="android-network-download" data-cdn-host=")[^"]*(")',
        lambda match: match[1] + match[2], page)
    if count != 1: raise ValueError('network Android pinned host drift')
    page, count = re.subn(r'(id="android-direct-download" href=")[^"]+(" download)',
        lambda match: match[1] + urlsplit(r['artifact_url']).path + match[2], page)
    if count != 1: raise ValueError('network Android fallback drift')
    page, count = re.subn(r'src="/src/download-redirect.js(?:\?[^"<>]*)?"',
        f'src="/src/download-redirect.js?v={r["build"]}-legacy"', page)
    if count != 1: raise ValueError('network Android startup script drift')
    # Keep the homepage bridge. Empty host disables the selector and its old
    # registry; the existing legacy router continues to the current APK alias.
    return {'download.html': page.encode('utf-8')}


def render_network_download(r, page, home):
    page, home = page.decode('utf-8'), home.decode('utf-8')
    host = urlsplit(r['cdn_url']).hostname
    if 'id="android-network-download"' not in page:
        page, count = re.subn(r'(<a )(class="land-btn land-btn-primary download-install" href="/downloads/latest-arm64.apk" download>下载 Android 版</a>)',
            lambda match: match[1] + 'id="android-network-download" data-cdn-host="" ' + match[2], page)
        if count != 1: raise ValueError('network primary link drift')
    page, count = re.subn(r'data-cdn-host="[^"]*"', f'data-cdn-host="{host}"', page)
    if count != 1: raise ValueError('network pinned host drift')
    if 'id="android-direct-download"' not in page:
        page, count = re.subn(r'<div class="download-alternatives">',
            '<div class="download-alternatives"><a id="android-direct-download" href="/downloads/latest-arm64.apk" download>备用下载</a>', page)
        if count != 1: raise ValueError('network fallback link drift')
    page, count = re.subn(r'(id="android-direct-download" href=")[^"]+(" download)',
        lambda match: match[1] + urlsplit(r['artifact_url']).path + match[2], page)
    if count != 1: raise ValueError('network fallback path drift')
    page, count = re.subn(r'src="/src/download-redirect.js(?:\?[^"<>]*)?"',
        f'src="/src/download-redirect.js?v={r["build"]}-network"', page)
    if count != 1: raise ValueError('network startup script drift')
    bridge = '"/download?platform=android&install=1"'
    if bridge not in home:
        home, count = re.subn(r'(function androidApkPath\(abi\) \{)(\r?\n)',
            lambda match: match[1] + match[2] + '  if (abi === "arm64") return ' + bridge + ';' + match[2], home)
        if count != 1: raise ValueError('network homepage helper drift')
        home, count = re.subn(r'(android.href = androidApkPath\("arm64"\);\r?\n)  android.setAttribute\("download", ""\);\r?\n',
            lambda match: match[1], home)
        if count != 1: raise ValueError('network homepage primary drift')
        home, count = re.subn(r'    android.setAttribute\("download", ""\);',
            '    if (abiSelect.value === "arm64") android.removeAttribute("download");\n    else android.setAttribute("download", "");', home)
        if count != 1: raise ValueError('network homepage ABI drift')
    return {'download.html': page.encode('utf-8'), 'src/admin-home.js': home.encode('utf-8'),
            'downloads/android-release.json': (json.dumps(network_registry(r), ensure_ascii=False, indent=2) + '\n').encode('utf-8')}


def fetch(url, method='GET'):
    # GET is for small metadata only. Even a malicious redirect cannot turn it
    # into an unbounded download; no APK/IPA GET is issued by this module.
    with urllib.request.urlopen(urllib.request.Request(url, method=method), timeout=15) as response:
        if urlsplit(response.url).scheme != 'https': raise ValueError('HTTPS required')
        data = b'' if method == 'HEAD' else response.read(262145)
        if len(data) > 262144: raise ValueError('metadata exceeds 256 KiB')
        return dict(response.headers.items()), data


def artifact_head(r, request=fetch):
    validate(r)
    headers, _ = request(r['artifact_url'], method='HEAD')
    headers = {k.lower(): v for k, v in headers.items()}
    if int(headers.get('content-length', '-1')) != r['artifact_bytes']:
        raise ValueError('artifact content length mismatch')


def check_network_download(r, request=fetch):
    headers, payload = request(BASE + '/downloads/android-release.json')
    headers = {key.lower(): value for key, value in headers.items()}
    if ('application/json' not in headers.get('content-type', '')
            or 'no-store' not in headers.get('cache-control', '')):
        raise ValueError('network registry MIME/cache mismatch')
    expected = network_registry(r)
    try:
        registry = json.loads(payload)
    except (ValueError, UnicodeError) as error:
        raise ValueError('invalid network registry') from error
    if registry != expected:
        raise ValueError('network registry differs from release')
    headers, _ = request(r['cdn_url'], method='HEAD')
    headers = {key.lower(): value for key, value in headers.items()}
    if (int(headers.get('content-length', '-1')) != r['artifact_bytes']
            or headers.get('content-type', '').split(';')[0].strip() not in (
                'application/vnd.android.package-archive', 'application/octet-stream')):
        raise ValueError('network CDN artifact MIME/length mismatch')
    _, page = request(BASE + '/download?platform=android&install=1')
    host = urlsplit(r['cdn_url']).hostname
    if (f'data-cdn-host="{host}"'.encode() not in page
            or b'id="android-network-download"' not in page
            or b'id="android-direct-download"' not in page):
        raise ValueError('network page does not expose pinned selector and fallback')
    for name, expected_sha in r['network_assets'].items():
        headers, payload = request(BASE + '/src/' + name)
        headers = {key.lower(): value for key, value in headers.items()}
        if ('javascript' not in headers.get('content-type', '')
                or hashlib.sha256(payload).hexdigest() != expected_sha):
            raise ValueError('network asset content/handoff mismatch')


def check_regular_android_download(r, request=fetch):
    _, page = request(BASE + '/download')
    backup = f'id="android-direct-download" href="{urlsplit(r["artifact_url"]).path}" download'.encode()
    script = f'src="/src/download-redirect.js?v={r["build"]}-legacy"'.encode()
    if (page.count(b'id="android-network-download"') != 1
            or page.count(b'id="android-direct-download"') != 1
            or page.count(b'id="android-network-download" data-cdn-host=""') != 1
            or page.count(backup) != 1 or page.count(script) != 1):
        raise ValueError('regular Android download page mismatch')


def check(r, request=fetch):
    artifact_head(r, request)
    if r.get('network_selection'):
        check_network_download(r, request)
    if r['platform'] == 'ios':
        headers, data = request(MANIFEST)
        d = plistlib.loads(data)
        if d != plistlib.loads(manifest(r)): raise ValueError('manifest differs from release record')
        headers = {k.lower(): v for k, v in headers.items()}
        if 'xml' not in headers.get('content-type', '') or 'no-store' not in headers.get('cache-control', ''):
            raise ValueError('manifest MIME/cache mismatch')
        _, page = request(BASE + '/download')
        _, home = request(BASE + '/src/admin-home.js')
        label = f"{r['version']}（{r['build']}）".encode()
        if label not in page or home.count(label) != 3: raise ValueError('stale version labels')
        if f'href="{urlsplit(r["artifact_url"]).path}" download'.encode() not in page:
            raise ValueError('stale desktop IPA link')
        if ('itms-services://?action=download-manifest&amp;url=' + MANIFEST).encode() not in page:
            raise ValueError('OTA entry missing')


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.release-')
    try:
        with os.fdopen(fd, 'wb') as handle: handle.write(data)
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)


# Public application service preserves audits, platform isolation and min-build.
# No administrator JWT is forged and no application tables are written directly.
SETTINGS_SCRIPT = Path(__file__).with_name('release_settings.py').read_text(encoding='utf-8')


def db_settings(payload):
    result = subprocess.check_output(['docker', 'exec', '-i', '-w', '/opt/business-api',
        'starchat-business-api-1', 'python3', '-', json.dumps(payload)], input=SETTINGS_SCRIPT.encode())
    return json.loads(result)


def publish(r, root, backup, request=fetch, db=db_settings):
    import fcntl
    validate(r)
    backup.mkdir(parents=True, exist_ok=False, mode=0o700)
    # Serialize this publisher on the host; fresh baseline plus CAS detects others.
    with open(root.parent / '.release-metadata.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        artifact_head(r, request)
        before = db({'mode': 'inspect'})
        if r.get('network_selection') and (before.get('app_latest_version') != r['version']
                or before.get('app_latest_build') != str(r['build'])):
            raise ValueError('network publication requires the existing release')
        prefix = 'app_ios_' if r['platform'] == 'ios' else 'app_'
        if int(before[prefix+'latest_build'] or 0) > r['build']:
            raise ValueError('release build rollback refused')
        desired = settings(r)
        staged = render(r, (root/'download.html').read_bytes(), (root/'src/admin-home.js').read_bytes())
        old = {name: (root/name).read_bytes() if (root/name).exists() else None for name in staged}
        (backup/'before.json').write_text(json.dumps(before), encoding='utf-8')
        (backup/'release.json').write_text(json.dumps(r), encoding='utf-8')
        for name, data in old.items():
            if data is not None:
                target = backup/name; target.parent.mkdir(parents=True, exist_ok=True);target.write_bytes(data)
        written = []
        try:
            for name, data in staged.items():
                if ((root/name).read_bytes() if (root/name).exists() else None) != old[name]:
                    raise ValueError('static drift: ' + name)
                atomic_write(root/name, data); written.append(name)
            check(r, request)  # HTTP/XML/page gates precede the update popup write.
            if (r['platform'] == 'android' and not r.get('network_selection')
                    and 'download.html' in staged):
                check_regular_android_download(r, request)
        except Exception:
            for name in reversed(written):
                if (root/name).read_bytes() == staged[name]:
                    if old[name] is None: (root/name).unlink()
                    else: atomic_write(root/name, old[name])
            raise
        # On ambiguous DB failure leave the verified files in place; persist
        # baseline and recover by inspecting the audit instead of blind replay.
        payload = {'mode': 'apply', 'expected': before, 'values': desired,
                   'trace': 'release-metadata-' + backup.name}
        if r.get('network_selection'):
            payload.update(network_selection=True,
                           existing_release={'version': r['version'], 'build': r['build']})
        after = db(payload)
        (backup/'after.json').write_text(json.dumps(after), encoding='utf-8')
        print('PUBLISH_PASS: metadata verified; binary inspection not performed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'check', 'publish'])
    parser.add_argument('record', type=Path)
    parser.add_argument('--root', type=Path, default=Path('/opt/starchat/frontend'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    r = json.loads(args.record.read_text(encoding='utf-8'));validate(r)
    if args.mode == 'check': check(r); print('METADATA_CHECK_PASS (no binary download)')
    elif args.mode == 'prepare':
        if not args.output: parser.error('--output required')
        for name, data in render(r, (args.root/'download.html').read_bytes(), (args.root/'src/admin-home.js').read_bytes()).items():
            atomic_write(args.output/name, data)
        atomic_write(args.output/'settings.json', json.dumps(settings(r)).encode())
    else:
        if not args.output or not args.output.resolve().is_relative_to(Path('/opt/starchat/docs/verification/artifacts')):
            parser.error('publish --output must be a NEW private backup directory under /opt/starchat/docs/verification/artifacts')
        publish(r, args.root, args.output)


if __name__ == '__main__': main()
