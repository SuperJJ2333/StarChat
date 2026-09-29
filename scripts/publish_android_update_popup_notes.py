"""Publish only the Android 0.4.24+2193 update-popup notes.

The APK, download website, registry, and version settings are already live.
Preflight is read-only. Execute uses the release-metadata host lock, a fresh
private backup, and a notes-only PostgreSQL transaction. The exact ten-setting
comparison, SettingService.set_many write, audit, and readback commit together.
An uncertain database response is never retried or silently rolled back;
inspect the saved trace and settings first.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import urlsplit


NEW_NOTES = '修复 USDT 提现报价显示异常；优化聊天搜索、朋友圈视频与部分页面体验。'
RELEASE_RECORD = Path(
    '/opt/starchat/releases/withdrawal-quote-2193-20260929/release-network.json')
RELEASE_RECORD_SHA256 = '5e2238f125ab10cdd1f1b97decb802e44d0395a8c99e42c0b4e9407fa3c4341c'
BASELINE = Path(
    '/opt/starchat/docs/verification/artifacts/2026-09-29/'
    'withdrawal-quote-2193-network-20260929T132929Z/after.json')
BASELINE_SHA256 = '8fa6b304c1e72b0c681fc69387dfc9c31086889c00ea8c34486428fd3595314c'
PRIVATE_BACKUP_ROOT = Path('/opt/starchat/docs/verification/artifacts')
PUBLIC_ROOT = Path('/opt/starchat/frontend')
DIRECT_URL = (
    'https://www.liuhetong888.com/downloads/'
    'ChatFlow-0.4.24-build2193-arm64.apk')
CDN_URL = (
    'https://d12fjr06o6tga5.cloudfront.net/downloads/'
    'ChatFlow-0.4.24-build2193-arm64.apk')
INSTALL_URL = 'https://www.liuhetong888.com/download?platform=android&install=1'
IOS_INSTALL_URL = 'https://www.liuhetong888.com/download?platform=ios&install=1'
ARTIFACT_SHA256 = '8ea9eafb95bcf07c5655266d3eb71766c5799ba364103b23004820f3cf4e6dec'
ARTIFACT_BYTES = 81767454
EXPECTED_RELEASE = {
    'platform': 'android', 'version': '0.4.24', 'build': 2193,
    'artifact_url': DIRECT_URL, 'artifact_bytes': ARTIFACT_BYTES,
    'signing_confirmed_by': (
        'Codex local final APK build: apksigner v2/v3 one-signer fixed certificate verified'),
    'artifact_sha256': ARTIFACT_SHA256,
    'source_commit': 'dae8ec6301e4c22d09721c6f54ccc9cc90bc6f3d',
    'mobile_manifest_sha256': 'bf3c85366adc5f468fcfdc8dfdf6787115169409daa97ed320d48f1479003f73',
    'signer_sha256': '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff',
    'package': 'com.liuhetong.mobile', 'abi': 'arm64-v8a',
    'network_selection': True, 'cdn_url': CDN_URL,
    'network_assets': {
        'download-redirect.js': 'a8f27e541081ae79c242dbccd075e780de7030cccf8c0d55c68dd5e7df5ac827',
        'download-network.js': '4699ca1c729138990d79b12303b30ec7b71335a97ebb2859bb914fd55bc0302a',
        'download-network-selector.js': 'a4030bc497d0453cc11f00a5bd4f567be8229a2ce822d93da738af211e6ab446',
    },
}
EXPECTED_STATIC_SHA256 = {
    'download.html': '83236b7332f698a036ee3d72a8e0000bfd82b34afece9a6d8178b50d139f6267',
    'downloads/android-release.json': 'c29b90b42ce7e707901ad4c97a0e8d173932e8e46a3136f8a7e6953b978b547a',
    'src/download-redirect.js': EXPECTED_RELEASE['network_assets']['download-redirect.js'],
    'src/download-network.js': EXPECTED_RELEASE['network_assets']['download-network.js'],
    'src/download-network-selector.js': EXPECTED_RELEASE['network_assets']['download-network-selector.js'],
}
SETTING_KEYS = frozenset((
    'app_latest_version', 'app_latest_build', 'app_min_supported_build',
    'app_update_notes', 'app_apk_url', 'app_ios_latest_version',
    'app_ios_latest_build', 'app_ios_min_supported_build',
    'app_ios_update_notes', 'app_ios_download_url',
))
FIXED_SETTINGS = {
    'app_latest_version': '0.4.24', 'app_latest_build': '2193',
    'app_min_supported_build': '3', 'app_apk_url': INSTALL_URL,
    'app_ios_latest_version': '0.4.20', 'app_ios_latest_build': '2189',
    'app_ios_min_supported_build': '3', 'app_ios_download_url': IOS_INSTALL_URL,
}
TRACE_PATTERN = re.compile(r'[A-Za-z0-9_.:-]{8,100}\Z')


def _release_metadata():
    source = Path(__file__).with_name('release_metadata.py')
    spec = importlib.util.spec_from_file_location('release_metadata', source)
    if spec is None or spec.loader is None:
        raise ValueError('release_metadata.py is unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path, value):
    payload = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode('utf-8')
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as target:
        target.write(payload)
        target.flush()
        os.fsync(target.fileno())


def _reject_symlink_segments(path, root):
    current = Path(path).absolute()
    root = Path(root).absolute()
    while True:
        if current.is_symlink():
            raise ValueError(f'symlink in public release path: {current}')
        if current == root:
            return
        if current == current.parent:
            raise ValueError('public release path escapes root')
        current = current.parent


def _validate(record, baseline, trace, expected_release):
    if record != expected_release:
        raise ValueError('Android 2193 network release record mismatch')
    _release_metadata().validate(record)
    if not isinstance(trace, str) or TRACE_PATTERN.fullmatch(trace) is None:
        raise ValueError('unique audit trace is invalid')
    if (not isinstance(baseline, dict) or set(baseline) != SETTING_KEYS
            or any(not isinstance(value, str) for value in baseline.values())):
        raise ValueError('ten-key Android 2193 settings baseline is invalid')
    if any(baseline[key] != value for key, value in FIXED_SETTINGS.items()):
        raise ValueError('Android 2193 or iOS 2189 settings baseline drift')
    if baseline['app_update_notes'] == NEW_NOTES:
        raise ValueError('Android 2193 update notes already published')
    if not baseline['app_update_notes'] or not baseline['app_ios_update_notes']:
        raise ValueError('update notes baseline is empty')


def _verify_local(record, root, expected_static_sha256):
    root = Path(root)
    if not root.is_dir():
        raise ValueError('public frontend root is missing')
    artifact = root / urlsplit(record['artifact_url']).path.lstrip('/')
    for path in (artifact, *(root / name for name in expected_static_sha256)):
        _reject_symlink_segments(path, root)
        if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f'public release file missing or outside root: {path}')
    if (artifact.stat().st_size != record['artifact_bytes']
            or _sha256(artifact) != record['artifact_sha256']):
        raise ValueError('server-local Android 2193 APK SHA256 or size mismatch')
    for name, digest in expected_static_sha256.items():
        if _sha256(root / name) != digest:
            raise ValueError(f'website static drift: {name}')


def _verify_public(record, expected_static_sha256, request):
    for url in (record['artifact_url'], record['cdn_url']):
        headers, _ = request(url, method='HEAD')
        headers = {key.lower(): value for key, value in headers.items()}
        if int(headers.get('content-length', '-1')) != record['artifact_bytes']:
            raise ValueError('Android 2193 public APK HEAD size mismatch')
    for name, digest in expected_static_sha256.items():
        url = ('https://www.liuhetong888.com/download' if name == 'download.html'
               else 'https://www.liuhetong888.com/' + name)
        _, data = request(url, method='GET')
        if not isinstance(data, bytes) or len(data) > 262144:
            raise ValueError(f'public website metadata exceeds limit: {name}')
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f'public website static drift: {name}')


AUDIT_SCRIPT = '''
import json,os,sys
from sqlalchemy import create_engine,select
from app.core.database import create_session_factory
from app.modules.audit.models import AuditEvent
p=json.loads(sys.argv[1])
factory=create_session_factory(create_engine(os.environ['BUSINESS_DATABASE_URL']))
with factory() as session:
 rows=session.scalars(select(AuditEvent).where(
  AuditEvent.trace_id==p['trace']
 ).order_by(AuditEvent.subject_type,AuditEvent.subject_id,AuditEvent.id)).all()
 print(json.dumps([{'subject_type':r.subject_type,'key':r.subject_id,
  'before':(r.before_data or {}).get('value'),
  'after':(r.after_data or {}).get('value'),'action':r.action,'result':r.result,
  'reason_code':r.reason_code} for r in rows]))
'''


def audit_settings(payload):
    output = subprocess.check_output([
        'docker', 'exec', '-i', '-w', '/opt/business-api',
        'starchat-business-api-1', 'python3', '-', json.dumps(payload),
    ], input=AUDIT_SCRIPT.encode('utf-8'))
    return json.loads(output)


# This one-time helper deliberately does not call release_metadata.db_settings:
# the production release_settings.py allows Android version/build/URL only.
# It follows that helper's PostgreSQL transaction and lock order but accepts
# exactly one Android notes key. AppSetting rows are locked, never written
# directly; SettingService owns the setting and audit writes.
SETTINGS_SCRIPT = '''
import json,os,re,sys
from sqlalchemy import create_engine,select,text
from sqlalchemy.orm import sessionmaker
from app.modules.settings.models import AppSetting
from app.modules.settings.service import (
 APP_UPDATE_SETTING_KEYS,APP_IOS_UPDATE_SETTING_KEYS,SettingService)
EXPECTED_NOTES=__EXPECTED_NOTES__
KEYS=APP_UPDATE_SETTING_KEYS+APP_IOS_UPDATE_SETTING_KEYS
p=json.loads(sys.argv[1]);mode=p.get('mode')
if mode not in ('inspect','apply'): raise ValueError('invalid settings operation')
if mode=='apply':
 values=p.get('values');expected=p.get('expected');trace=p.get('trace')
 if values!={'app_update_notes':EXPECTED_NOTES}:
  raise ValueError('Android 2193 notes only')
 if (not isinstance(expected,dict) or set(expected)!=set(KEYS)
  or any(not isinstance(v,str) for v in expected.values())):
  raise ValueError('invalid ten-key settings handoff')
 if not isinstance(trace,str) or re.fullmatch(r'[A-Za-z0-9_.:-]{8,100}',trace) is None:
  raise ValueError('invalid audit trace')
engine=create_engine(os.environ['BUSINESS_DATABASE_URL'])
try:
 if mode=='apply' and engine.dialect.name != 'postgresql':
  raise RuntimeError('PostgreSQL is required for atomic notes publication')
 with engine.begin() as connection:
  if mode=='apply':
   connection.execute(text('SELECT pg_advisory_xact_lock(1937006964, 1)'))
   existing=set(connection.scalars(select(AppSetting.key)
    .where(AppSetting.key.in_(KEYS)).order_by(AppSetting.key).with_for_update()))
   if existing!=set(KEYS): raise RuntimeError('Update settings rows missing; no write')
  sessions=sessionmaker(bind=connection,autoflush=False,expire_on_commit=False,
   join_transaction_mode='create_savepoint')
  service=SettingService(sessions)
  before=service.get_many(KEYS)
  if mode=='inspect':
   after=before
  else:
   if before != expected: raise RuntimeError('Settings drift; no write')
   if before['app_update_notes']==EXPECTED_NOTES:
    raise RuntimeError('Android 2193 notes already published; no write')
   service.set_many({'app_update_notes': EXPECTED_NOTES},
    actor_id='ops-release-metadata',trace_id=trace)
   after=service.get_many(KEYS)
   if after != before | values:
    raise RuntimeError('Settings readback mismatch; transaction rolled back')
 print(json.dumps(after))
finally:
 engine.dispose()
'''.replace('__EXPECTED_NOTES__', repr(NEW_NOTES))


def db_settings_notes(payload):
    mode = payload.get('mode')
    if mode == 'inspect':
        if set(payload) != {'mode'}:
            raise ValueError('inspect accepts no other arguments')
    elif mode == 'apply':
        expected = payload.get('expected')
        if (set(payload) != {'mode', 'expected', 'values', 'trace'}
                or payload.get('values') != {'app_update_notes': NEW_NOTES}
                or not isinstance(expected, dict) or set(expected) != SETTING_KEYS
                or any(not isinstance(value, str) for value in expected.values())
                or not isinstance(payload.get('trace'), str)
                or TRACE_PATTERN.fullmatch(payload['trace']) is None):
            raise ValueError('Android 2193 notes only with exact ten-key expected state')
    else:
        raise ValueError('invalid settings operation')
    output = subprocess.check_output([
        'docker', 'exec', '-i', '-w', '/opt/business-api',
        'starchat-business-api-1', 'python3', '-', json.dumps(payload),
    ], input=SETTINGS_SCRIPT.encode('utf-8'))
    return json.loads(output)


def _verify_audit(rows, before):
    expected = [{
        'subject_type': 'app_setting', 'key': 'app_update_notes',
        'before': before['app_update_notes'],
        'after': NEW_NOTES, 'action': 'settings.update', 'result': 'SUCCESS',
        'reason_code': 'ADMIN_SETTING_UPDATED',
    }]
    if rows != expected:
        raise ValueError('Android 2193 update notes audit differs from one expected write')


def _inspect(record, baseline, root, trace, *, request, db, audit,
             expected_release, expected_static_sha256):
    _validate(record, baseline, trace, expected_release)
    if set(expected_static_sha256) != set(EXPECTED_STATIC_SHA256):
        raise ValueError('five Android release static paths are required')
    if record['network_assets'] != {
            name.removeprefix('src/'): expected_static_sha256[name]
            for name in expected_static_sha256 if name.startswith('src/')}:
        raise ValueError('Android 2193 network assets differ from static evidence')
    _verify_local(record, root, expected_static_sha256)
    _verify_public(record, expected_static_sha256, request)
    _verify_local(record, root, expected_static_sha256)
    before = db({'mode': 'inspect'})
    if before != baseline:
        raise ValueError('ten-key app update settings drift; no write')
    audit_before = audit({'trace': trace})
    if audit_before != []:
        raise ValueError('audit trace already exists; no write')
    return {
        'artifact_sha256': record['artifact_sha256'],
        'artifact_bytes': record['artifact_bytes'],
        'static_sha256': expected_static_sha256,
        'settings_before': before, 'audit_trace': trace,
        'audit_before': audit_before,
    }


def preflight(record, baseline, root, trace, *, request=None, db=None,
              audit=None, expected_release=EXPECTED_RELEASE,
              expected_static_sha256=EXPECTED_STATIC_SHA256):
    """Read-only preflight. Execute repeats every check under the host lock."""
    release = _release_metadata()
    return _inspect(
        record, baseline, root, trace, request=request or release.fetch,
        db=db or db_settings_notes, audit=audit or audit_settings,
        expected_release=expected_release,
        expected_static_sha256=expected_static_sha256,
    )


def _check_backup_path(backup, root, allowed_backup_root):
    backup = Path(backup)
    allowed = Path(allowed_backup_root).resolve()
    if (not allowed.is_dir() or backup.resolve() == allowed
            or not backup.resolve().is_relative_to(allowed)
            or backup.resolve().is_relative_to(Path(root).resolve())
            or backup.exists()):
        raise ValueError('backup must be a fresh private child outside the public root')


def publish(record, baseline, root, backup, trace, *, request=None,
            db=None, audit=None, allowed_backup_root=PRIVATE_BACKUP_ROOT,
            expected_release=EXPECTED_RELEASE,
            expected_static_sha256=EXPECTED_STATIC_SHA256):
    """Change one Android setting once; retain any ambiguous result for audit."""
    import fcntl

    root, backup = Path(root), Path(backup)
    _check_backup_path(backup, root, allowed_backup_root)
    release = _release_metadata()
    request = request or release.fetch
    db = db or db_settings_notes
    audit = audit or audit_settings
    with (root.parent / '.release-metadata.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before_result = _inspect(
            record, baseline, root, trace, request=request, db=db, audit=audit,
            expected_release=expected_release,
            expected_static_sha256=expected_static_sha256,
        )
        _check_backup_path(backup, root, allowed_backup_root)
        backup.mkdir(parents=True, mode=0o700, exist_ok=False)
        os.chmod(backup, 0o700)
        _write_json(backup / 'before.json', before_result)
        _write_json(backup / 'release.json', record)
        desired = dict(baseline, app_update_notes=NEW_NOTES)
        try:
            # db_settings_notes locks all ten rows, compares expected values,
            # writes only notes via SettingService and reads back in one txn.
            after = db({
                'mode': 'apply', 'expected': baseline,
                'values': {'app_update_notes': NEW_NOTES}, 'trace': trace,
            })
            if after != desired or db({'mode': 'inspect'}) != desired:
                raise ValueError('ten-key app update settings readback mismatch')
            rows = audit({'trace': trace})
            _verify_audit(rows, baseline)
            _verify_local(record, root, expected_static_sha256)
        except Exception:
            _write_json(backup / 'outcome-unknown.json', {
                'audit_trace': trace,
                'action': 'Inspect current ten settings and this audit trace; do not replay or silently roll back.',
            })
            raise
        result = {
            'artifact_sha256': record['artifact_sha256'],
            'settings_before': baseline, 'settings_after': desired,
            'changed_keys': ['app_update_notes'],
            'audit_trace': trace, 'audit_count': len(rows), 'audit': rows,
            'static_sha256': expected_static_sha256,
        }
        _write_json(backup / 'result.json', result)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('preflight', 'execute'))
    parser.add_argument('--backup', type=Path,
                        help='new 0700 directory under the private verification root')
    parser.add_argument('--trace', required=True)
    args = parser.parse_args(argv)
    if args.mode == 'execute' and args.backup is None:
        parser.error('execute requires --backup')
    if args.mode == 'preflight' and args.backup is not None:
        parser.error('preflight does not create a backup')
    if _sha256(RELEASE_RECORD) != RELEASE_RECORD_SHA256:
        raise ValueError('exact Android 2193 network release record SHA256 mismatch')
    if _sha256(BASELINE) != BASELINE_SHA256:
        raise ValueError('exact Android 2193 network settings snapshot SHA256 mismatch')
    record = json.loads(RELEASE_RECORD.read_text(encoding='utf-8'))
    baseline = json.loads(BASELINE.read_text(encoding='utf-8'))
    if args.mode == 'preflight':
        result = preflight(record, baseline, PUBLIC_ROOT, args.trace)
        print('ANDROID_2193_POPUP_PREFLIGHT_PASS ' + json.dumps({
            'artifact_sha256': result['artifact_sha256'],
            'version': record['version'], 'build': record['build'],
            'audit_trace': args.trace,
        }))
    else:
        result = publish(record, baseline, PUBLIC_ROOT, args.backup, args.trace)
        print('ANDROID_2193_POPUP_PUBLISH_PASS ' + json.dumps({
            'artifact_sha256': result['artifact_sha256'],
            'version': record['version'], 'build': record['build'],
            'audit_count': result['audit_count'], 'backup': str(args.backup),
        }))


if __name__ == '__main__':
    main()
