"""Publish small release metadata. Never download or inspect APK/IPA bytes.

Run prepare/check anywhere; publish on the production host. Signing confirmation
is an operator attestation, not a claim that this script verifies signatures.
"""
import argparse
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
    if not str(r.get('signing_confirmed_by', '')).strip():
        raise ValueError('final signing handoff must be confirmed by release owner')
    if r['platform'] == 'ios' and r.get('bundle_id') != BUNDLE:
        raise ValueError('bundle identity changed')


def settings(r):
    validate(r)
    if r['platform'] == 'ios':
        return {'app_ios_latest_version': r['version'], 'app_ios_latest_build': str(r['build']),
                'app_ios_download_url': INSTALL}
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
    if r['platform'] != 'ios':
        return {}
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


def check(r, request=fetch):
    artifact_head(r, request)
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
SETTINGS_SCRIPT = '''
import json,os,sys
from sqlalchemy import create_engine
from app.core.database import create_session_factory
from app.modules.settings.service import SettingService,APP_UPDATE_SETTING_KEYS,APP_IOS_UPDATE_SETTING_KEYS
p=json.loads(sys.argv[1]);s=SettingService(create_session_factory(create_engine(os.environ['BUSINESS_DATABASE_URL'])))
keys=APP_UPDATE_SETTING_KEYS+APP_IOS_UPDATE_SETTING_KEYS
before=s.get_many(keys)
if p['mode']=='apply':
 if before!=p['expected']: raise RuntimeError('Settings drift; no write')
 if any(before[k]!=v for k,v in p['values'].items()):
  s.set_many(p['values'],actor_id='ops-release-metadata',trace_id=p['trace'])
 after=s.get_many(keys)
 if any(after[k]!=(p['values'][k] if k in p['values'] else v) for k,v in before.items()):
  raise RuntimeError('Settings readback mismatch')
 print(json.dumps(after))
else: print(json.dumps(before))
'''


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
        except Exception:
            for name in reversed(written):
                if (root/name).read_bytes() == staged[name]:
                    if old[name] is None: (root/name).unlink()
                    else: atomic_write(root/name, old[name])
            raise
        # On ambiguous DB failure leave the verified files in place; persist
        # baseline and recover by inspecting the audit instead of blind replay.
        after = db({'mode': 'apply', 'expected': before, 'values': desired,
                    'trace': 'release-metadata-' + backup.name})
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
