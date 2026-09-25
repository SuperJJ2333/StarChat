"""Enable the already-published iOS 0.4.7/2173 update popup, with exact CAS.

The website-only release must already be live. This command hashes the server's
immutable IPA and static files, checks public HEAD/small metadata, saves the
ten-key setting and audit baseline privately, then updates only the iOS version,
build and notes through SettingService.set_many. It never GETs the public IPA.
An ambiguous DB failure is left for inspection; this command never rolls back
an audited settings write without a separate, audited correction.
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


STATIC_NAMES = ('download.html', 'src/admin-home.js', 'downloads/ios/manifest.plist')
SETTING_KEYS = frozenset((
    'app_latest_version', 'app_latest_build', 'app_min_supported_build',
    'app_update_notes', 'app_apk_url', 'app_ios_latest_version',
    'app_ios_latest_build', 'app_ios_min_supported_build',
    'app_ios_update_notes', 'app_ios_download_url',
))
CHANGED_KEYS = ('app_ios_latest_version', 'app_ios_latest_build',
                'app_ios_update_notes')
PRIVATE_BACKUP_ROOT = Path('/opt/starchat/docs/verification/artifacts')
EXPECTED_ARTIFACT_URL = (
    'https://www.liuhetong888.com/downloads/ios/ChatFlow-0.4.7-build2173.ipa')
EXPECTED_DIFFERENCES = [
    'added Payload path: Payload/Runner.app/Frameworks/AppRuntime/ATHelper.dylib',
    'added Payload path: Payload/Runner.app/Frameworks/Partner/libutils.dylib',
    'added Payload path: Payload/Runner.app/flag',
    'Payload/Runner.app/Runner: Mach-O load commands changed for CPU 100000c',
]


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
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True),
                    encoding='utf-8')


def _reject_symlink_segments(path, root):
    current = path.absolute()
    root = root.absolute()
    while True:
        if current.is_symlink():
            raise ValueError(f'symlink in public release path: {current}')
        if current == root:
            return
        if current == current.parent:
            raise ValueError('public release path escapes root')
        current = current.parent


def _validate_record(record, static_result, notes, trace):
    release = _release_metadata()
    release.validate(record)
    if (record['platform'] != 'ios' or record['version'] != '0.4.7'
            or record['build'] != 2173
            or record['artifact_url'] != EXPECTED_ARTIFACT_URL
            or record.get('publication_scope') !=
            'website_ios_links_only_no_app_update_settings'):
        raise ValueError('record is not the website-only iOS 0.4.7/2173 release')
    if (not isinstance(notes, str) or not notes.strip() or len(notes) > 255
            or any(ord(char) < 32 for char in notes)):
        raise ValueError('iOS update notes must be 1–255 printable characters')
    if not isinstance(trace, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{8,100}', trace):
        raise ValueError('unique audit trace is invalid')
    evidence = record.get('ios_ipa_evidence')
    exception = record.get('payload_exception')
    expected = record.get('expected_app_settings_before')
    if (not isinstance(evidence, dict) or not isinstance(exception, dict)
            or not isinstance(expected, dict) or set(expected) != SETTING_KEYS
            or any(not isinstance(value, str) for value in expected.values())
            or expected['app_ios_latest_version'] != '0.3.102'
            or expected['app_ios_latest_build'] != '2144'
            or expected['app_ios_min_supported_build'] != '3'
            or expected['app_ios_download_url'] != release.INSTALL):
        raise ValueError('exact ten-key 2144 app settings baseline is missing')
    digest = evidence.get('sha256')
    if (not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest)
            or evidence.get('artifact_bytes') not in (None, record['artifact_bytes'])
            or exception.get('final_sha256') != digest
            or exception.get('candidate_sha256') != record['ios_ci_candidate_sha256']
            or exception.get('expected_differences') != EXPECTED_DIFFERENCES
            or exception.get('payload_comparison_status') != 'fail'
            or not str(exception.get('authorized_by', '')).strip()
            or not str(exception.get('reason', '')).strip()):
        raise ValueError('exact user-authorized enterprise signer exception is missing')
    if (not isinstance(static_result, dict)
            or static_result.get('artifact_url') != record['artifact_url']
            or static_result.get('artifact_sha256') != digest
            or static_result.get('artifact_bytes') != record['artifact_bytes']
            or static_result.get('payload_exception') != exception
            or static_result.get('settings_before') != expected
            or static_result.get('settings_after') != expected
            or not isinstance(static_result.get('static_after_sha256'), dict)
            or set(static_result['static_after_sha256']) != set(STATIC_NAMES)
            or any(not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value)
                   for value in static_result['static_after_sha256'].values())):
        raise ValueError('website-only publication result does not bind to this release')
    return release


def _verify_live_files(record, static_result, root):
    artifact = root / urlsplit(record['artifact_url']).path.lstrip('/')
    for path in (artifact, *(root / name for name in STATIC_NAMES)):
        _reject_symlink_segments(path, root)
        if not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f'public release file missing or outside root: {path}')
    if (artifact.stat().st_size != record['artifact_bytes']
            or _sha256(artifact) != record['ios_ipa_evidence']['sha256']):
        raise ValueError('server-local immutable IPA SHA256 or size mismatch')
    for name, expected_sha in static_result['static_after_sha256'].items():
        if _sha256(root / name) != expected_sha:
            raise ValueError(f'website static drift: {name}')


AUDIT_SCRIPT = '''
import json,os,sys
from sqlalchemy import create_engine,select
from app.core.database import create_session_factory
from app.modules.audit.models import AuditEvent
p=json.loads(sys.argv[1])
factory=create_session_factory(create_engine(os.environ['BUSINESS_DATABASE_URL']))
with factory() as session:
 rows=session.scalars(select(AuditEvent).where(
  AuditEvent.trace_id==p['trace'], AuditEvent.subject_type=='app_setting'
 ).order_by(AuditEvent.subject_id,AuditEvent.id)).all()
 print(json.dumps([{'key':r.subject_id,'before':(r.before_data or {}).get('value'),
  'after':(r.after_data or {}).get('value'),'action':r.action,'result':r.result,
  'reason_code':r.reason_code} for r in rows]))
'''


def audit_settings(payload):
    output = subprocess.check_output([
        'docker', 'exec', '-i', '-w', '/opt/business-api',
        'starchat-business-api-1', 'python3', '-', json.dumps(payload),
    ], input=AUDIT_SCRIPT.encode('utf-8'))
    return json.loads(output)


def _verify_audit(rows, before, after):
    expected = [
        {'key': key, 'before': before[key], 'after': after[key],
         'action': 'settings.update', 'result': 'SUCCESS',
         'reason_code': 'ADMIN_SETTING_UPDATED'}
        for key in CHANGED_KEYS
    ]
    if not isinstance(rows, list) or sorted(rows, key=lambda row: row['key']) != sorted(
            expected, key=lambda row: row['key']):
        raise ValueError('iOS update setting audit differs from three expected writes')


def publish(record, static_result, root, backup, notes, trace, *, request=None,
            db=None, audit=None, allowed_backup_root=PRIVATE_BACKUP_ROOT):
    """Publish three iOS settings after exact release and ten-key CAS checks."""
    import fcntl

    release = _validate_record(record, static_result, notes, trace)
    root, backup = Path(root), Path(backup)
    allowed_root = Path(allowed_backup_root).resolve()
    if (not root.is_dir() or backup.resolve() == allowed_root
            or not backup.resolve().is_relative_to(allowed_root)
            or backup.resolve().is_relative_to(root.resolve())
            or backup.exists()):
        raise ValueError('backup must be a fresh private child outside the public root')
    request = request or release.fetch
    db = db or release.db_settings
    audit = audit or audit_settings
    expected = record['expected_app_settings_before']
    desired_values = {
        'app_ios_latest_version': record['version'],
        'app_ios_latest_build': str(record['build']),
        'app_ios_update_notes': notes,
    }
    desired = dict(expected, **desired_values)
    if any(expected[key] == desired_values[key] for key in CHANGED_KEYS):
        raise ValueError('popup release must change exactly three iOS values')

    with (root.parent / '.release-metadata.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _verify_live_files(record, static_result, root)
        release.check(record, request)
        _verify_live_files(record, static_result, root)
        before = db({'mode': 'inspect'})
        if before != expected:
            raise ValueError('ten-key app update settings drift; no write')
        audit_before = audit({'trace': trace})
        if audit_before != []:
            raise ValueError('audit trace already exists; no write')
        backup.mkdir(parents=True, mode=0o700)
        os.chmod(backup, 0o700)
        _write_json(backup / 'before.json', {
            'settings': before, 'audit': audit_before,
            'static_sha256': static_result['static_after_sha256'],
            'artifact_sha256': record['ios_ipa_evidence']['sha256'],
            'artifact_bytes': record['artifact_bytes'],
            'trace': trace,
        })
        _write_json(backup / 'release.json', record)
        _write_json(backup / 'static-result.json', static_result)
        # db_settings checks all ten keys again immediately before set_many.
        # If its outcome is ambiguous, inspect the trace and current settings;
        # never blindly replay or issue a silent rollback.
        after = db({'mode': 'apply', 'expected': before,
                    'values': desired_values, 'trace': trace})
        if after != desired or db({'mode': 'inspect'}) != desired:
            raise ValueError('ten-key app update settings readback mismatch')
        audit_after = audit({'trace': trace})
        _verify_audit(audit_after, before, desired)
        result = {
            'artifact_url': record['artifact_url'],
            'artifact_sha256': record['ios_ipa_evidence']['sha256'],
            'settings_before': before, 'settings_after': desired,
            'changed_keys': list(CHANGED_KEYS),
            'audit_trace': trace, 'audit_count': len(audit_after),
            'audit': audit_after,
        }
        _write_json(backup / 'result.json', result)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=Path)
    parser.add_argument('--static-result', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--backup', type=Path, required=True)
    parser.add_argument('--notes', required=True)
    parser.add_argument('--trace', required=True)
    args = parser.parse_args(argv)
    record = json.loads(args.record.read_text(encoding='utf-8'))
    static_result = json.loads(args.static_result.read_text(encoding='utf-8'))
    result = publish(record, static_result, args.root, args.backup,
                     args.notes, args.trace)
    print('IOS_UPDATE_POPUP_PUBLISH_PASS ' + json.dumps({
        'artifact_sha256': result['artifact_sha256'],
        'latest_version': result['settings_after']['app_ios_latest_version'],
        'latest_build': result['settings_after']['app_ios_latest_build'],
        'audit_count': result['audit_count'], 'backup': str(args.backup),
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()
