"""Publish small release metadata without downloading APK/IPA bytes.

Run prepare/check anywhere; publish on the production host. iOS publish requires
evidence from the final signed IPA and checks the uploaded local file's SHA256.
This module does not independently verify Apple signatures or device installation.
"""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

BASE = 'https://www.liuhetong888.com'
INSTALL = BASE + '/download?platform=ios&install=1'
MANIFEST = BASE + '/downloads/ios/manifest.plist'
BUNDLE = 'com.liuhetong.liuhetongMobile'
LEGACY_IOS_APP_ID = 'ZXB3TS7QD4.cn.edu.buaa.wxwork.notifyext'


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
    if r['platform'] == 'ios' and not re.fullmatch(
            r'[0-9a-f]{64}', str(r.get('ios_ci_candidate_sha256', ''))):
        raise ValueError('iOS CI candidate SHA256 is required in the release record')
    legacy_app_id = r.get('ios_legacy_application_identifier')
    if legacy_app_id is not None and (
            r['platform'] != 'ios' or legacy_app_id != LEGACY_IOS_APP_ID):
        raise ValueError('unsupported legacy iOS application identifier')
    if legacy_app_id is not None and r.get('ios_allow_no_apns') is True:
        raise ValueError('legacy iOS recovery release requires production APNs')


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


def inspect_uploaded_ios_ipa(path, r):
    """Reinspect the uploaded IPA, independently of the editable release JSON."""
    checker = Path(__file__).with_name('verify_ios_enterprise_ipa.py')
    spec = importlib.util.spec_from_file_location('verify_ios_enterprise_ipa', checker)
    if spec is None or spec.loader is None:
        raise ValueError('iOS IPA inspector is unavailable on the release host')
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        return module.inspect_ipa(
            path,
            expected_bundle_id=r['bundle_id'],
            expected_version=r['version'],
            expected_build=r['build'],
            expected_team_id=r['ios_ipa_evidence']['team_id'],
            expected_legacy_application_identifier=r.get(
                'ios_legacy_application_identifier'),
            require_apns=r.get('ios_allow_no_apns') is not True,
        )
    except (OSError, zipfile.BadZipFile) as exc:
        raise ValueError('uploaded iOS IPA inspection failed') from exc


def compare_uploaded_ios_payload(candidate, final):
    """Load the strict CI-to-enterprise IPA payload checker on the release host."""
    checker = Path(__file__).with_name('compare_ios_ipa_payload.py')
    spec = importlib.util.spec_from_file_location('compare_ios_ipa_payload', checker)
    if spec is None or spec.loader is None:
        raise ValueError('iOS IPA payload comparator is unavailable on the release host')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.compare_ipa_payload(candidate, final)


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_ios_payload_comparison(r, root, candidate, *, comparator=None):
    """Check actual CI and final IPA bytes against both recorded immutable hashes."""
    if r['platform'] != 'ios':
        return None
    if candidate is None:
        raise ValueError('iOS CI candidate IPA path is required for publish')
    candidate = Path(candidate).resolve()
    if not candidate.is_file():
        raise ValueError('iOS CI candidate IPA is missing on release host')
    root = Path(root).resolve()
    final = (root / urlsplit(r['artifact_url']).path.lstrip('/')).resolve()
    if not final.is_relative_to(root) or not final.is_file():
        raise ValueError('uploaded final iOS IPA is missing')
    candidate_sha = r['ios_ci_candidate_sha256']
    final_sha = r['ios_ipa_evidence']['sha256']
    if candidate == final or candidate_sha == final_sha:
        raise ValueError('CI candidate must be distinct from final enterprise IPA')
    if sha256_file(candidate) != candidate_sha:
        raise ValueError('local iOS CI candidate SHA256 differs from release record')
    if sha256_file(final) != final_sha:
        raise ValueError('uploaded final iOS IPA SHA256 differs from handoff evidence')
    compare = comparator or compare_uploaded_ios_payload
    report = compare(candidate, final)
    if (not isinstance(report, dict) or report.get('status') != 'pass'
            or report.get('differences') != []
            or report.get('candidate_sha256') != candidate_sha
            or report.get('final_sha256') != final_sha
            or type(report.get('payload_path_count')) is not int
            or report['payload_path_count'] <= 0
            or type(report.get('final_payload_path_count')) is not int
            or report['final_payload_path_count'] <= 0):
        raise ValueError('iOS CI candidate and final IPA payload comparison failed')
    # Detect replacements while the comparator was reading either file.
    if sha256_file(candidate) != candidate_sha or sha256_file(final) != final_sha:
        raise ValueError('iOS IPA SHA256 changed during payload comparison')
    return report


def verify_ios_release_evidence(r, root, *, inspector=None):
    """Bind handoff inspection to the exact IPA uploaded for this release."""
    validate(r)
    if r['platform'] != 'ios':
        return
    evidence = r.get('ios_ipa_evidence')
    if not isinstance(evidence, dict):
        raise ValueError('iOS signed IPA evidence is required before publish')
    team_id = evidence.get('team_id')
    if not isinstance(team_id, str) or not re.fullmatch(r'[A-Z0-9]{10}', team_id):
        raise ValueError('iOS enterprise team identity is invalid')
    legacy_app_id = r.get('ios_legacy_application_identifier')
    if legacy_app_id is not None and team_id != 'ZXB3TS7QD4':
        raise ValueError('legacy iOS application identifier requires original Team')
    expected_app_id = legacy_app_id or team_id + '.' + r['bundle_id']
    if (evidence.get('bundle_id') != r['bundle_id']
            or evidence.get('version') != r['version']
            or type(evidence.get('build')) is not int
            or evidence['build'] != r['build']
            or evidence.get('profile_application_identifier') != expected_app_id
            or evidence.get('signed_application_identifier') != expected_app_id):
        raise ValueError('iOS signed IPA identity does not match release record')
    if evidence.get('get_task_allow') is not False or evidence.get('provisions_all_devices') is not True:
        raise ValueError('iOS signed IPA is not an enterprise distribution build')
    if type(evidence.get('artifact_bytes')) is not int or evidence['artifact_bytes'] != r['artifact_bytes']:
        raise ValueError('iOS signed IPA evidence size differs from release record')
    profile_groups = evidence.get('profile_keychain_access_groups')
    signed_groups = evidence.get('signed_keychain_access_groups')
    for groups in (profile_groups, signed_groups):
        if (not isinstance(groups, list) or not groups
                or any(not isinstance(group, str) or not group for group in groups)
                or len(groups) != len(set(groups))
                or not any(group.startswith(team_id + '.') for group in groups)):
            raise ValueError('iOS Keychain group evidence is missing or invalid')
    for group in signed_groups:
        if not any(
            group == allowed or (
                allowed.endswith('*') and allowed.count('*') == 1
                and group.startswith(allowed[:-1])
            )
            for allowed in profile_groups
        ):
            raise ValueError('signed iOS Keychain group is not allowed by profile')
    baseline = r.get('ios_upgrade_from')
    if not isinstance(baseline, dict):
        raise ValueError('installed iOS upgrade baseline is required to preserve app data')
    old_groups = baseline.get('keychain_access_groups')
    if (baseline.get('team_id') != team_id
            or baseline.get('application_identifier') != expected_app_id
            or not isinstance(baseline.get('version'), str)
            or not re.fullmatch(r'\d+\.\d+\.\d+', baseline['version'])
            or type(baseline.get('build')) is not int
            or baseline['build'] <= 0 or baseline['build'] >= r['build']
            or not isinstance(old_groups, list) or not old_groups
            or any(not isinstance(group, str) or not group for group in old_groups)
            or signed_groups[0] != old_groups[0]
            or any(group not in signed_groups for group in old_groups)):
        raise ValueError('iOS upgrade identity or Keychain baseline cannot preserve app data')
    upgrade_test = r.get('ios_upgrade_test')
    if not isinstance(upgrade_test, dict):
        raise ValueError('iOS device cover-install test is required before publish')
    performed_at = upgrade_test.get('performed_at')
    try:
        test_time = datetime.fromisoformat(performed_at) if isinstance(performed_at, str) else None
    except ValueError:
        test_time = None
    if (upgrade_test.get('candidate_sha256') != evidence.get('sha256')
            or upgrade_test.get('old_version') != baseline['version']
            or type(upgrade_test.get('old_build')) is not int
            or upgrade_test['old_build'] != baseline['build']
            or test_time is None or test_time.tzinfo is None
            or not isinstance(upgrade_test.get('performed_by'), str)
            or not upgrade_test['performed_by'].strip()
            or upgrade_test.get('installed_without_uninstall') is not True
            or upgrade_test.get('pre_upgrade_healthy') is not True
            or upgrade_test.get('chat_history_preserved') is not True
            or upgrade_test.get('login_preserved') is not True
            or upgrade_test.get('keychain_preserved') is not True
            or upgrade_test.get('background_notifications_confirmed') is not True):
        raise ValueError('iOS device cover-install test does not prove this candidate preserved data')
    apns = evidence.get('aps_environment')
    if apns != 'production' and not (apns is None and r.get('ios_allow_no_apns') is True):
        raise ValueError('production APNs evidence is required')
    digest = evidence.get('sha256')
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('invalid iOS signed IPA SHA256 evidence')
    root = Path(root).resolve()
    artifact = (root / urlsplit(r['artifact_url']).path.lstrip('/')).resolve()
    if not artifact.is_relative_to(root) or not artifact.is_file():
        raise ValueError('uploaded iOS IPA file is missing')
    if artifact.stat().st_size != r['artifact_bytes']:
        raise ValueError('uploaded iOS IPA size differs from release record')
    sha256 = hashlib.sha256()
    with artifact.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            sha256.update(chunk)
    if sha256.hexdigest() != digest:
        raise ValueError('uploaded iOS IPA SHA256 differs from signed handoff evidence')
    inspected = (inspector(artifact) if inspector is not None
                 else inspect_uploaded_ios_ipa(artifact, r))
    if inspected != evidence:
        raise ValueError('uploaded iOS IPA inspection differs from signed handoff evidence')


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


def publish(r, root, backup, request=fetch, db=db_settings, *, inspector=None,
            candidate=None, comparator=None):
    import fcntl
    validate(r)
    # Serialize this publisher on the host; fresh baseline plus CAS detects others.
    with open(root.parent / '.release-metadata.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        verify_ios_release_evidence(r, root, inspector=inspector)
        verify_ios_payload_comparison(r, root, candidate, comparator=comparator)
        backup.mkdir(parents=True, exist_ok=False, mode=0o700)
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
            verify_ios_release_evidence(r, root, inspector=inspector)  # Catch a same-path IPA replacement.
            comparison = verify_ios_payload_comparison(
                r, root, candidate, comparator=comparator)
            if comparison is not None:
                (backup/'ios-payload-comparison.json').write_text(
                    json.dumps(comparison, ensure_ascii=False, indent=2, sort_keys=True),
                    encoding='utf-8')
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
        if r['platform'] == 'ios':
            print('PUBLISH_PASS: metadata, signed IPA and CI payload comparison verified')
        else:
            print('PUBLISH_PASS: metadata verified; binary inspection not performed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['prepare', 'check', 'publish'])
    parser.add_argument('record', type=Path)
    parser.add_argument('--root', type=Path, default=Path('/opt/starchat/frontend'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--ios-candidate', type=Path,
                        help='local immutable CI-generated IPA used to verify enterprise re-sign')
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
        if r['platform'] == 'ios' and args.ios_candidate is None:
            parser.error('iOS publish requires --ios-candidate <local CI IPA>')
        publish(r, args.root, args.output, candidate=args.ios_candidate)


if __name__ == '__main__': main()
