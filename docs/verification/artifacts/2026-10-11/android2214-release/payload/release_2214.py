"""One record: offline prepare, read-only check, guarded Android 2214 publish.

No command is executed merely by importing this module. Cloud/binary installation
must complete independently before publish. No repository-wide deployment.
"""
import argparse
import copy
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
INSTALL = 'https://www.liuhetong888.com/download?platform=android&install=1'
IOS_INSTALL = 'https://www.liuhetong888.com/download?platform=ios&install=1'
NOTES = '改进发送队列、历史加载和媒体缓存，增加媒体任务恢复和大小预检，优化Android后台运行稳定性。当前普通附件最高48MiB，图片因解码预算上限更低；过大时请压缩或缩小后重试。'
OLD_NAME = 'ChatFlow-0.4.44-build2213-arm64.apk'
NAME = 'ChatFlow-0.4.45-build2214-arm64.apk'
OLD_SHA = '08a7448114ad5d768b534b81b61668e03a71a2c26f95e894297e098838f15271'
OLD_PATHS = ['downloads/ChatFlow-0.4.19-build2188-arm64.apk','downloads/ChatFlow-0.4.21-build2190-arm64.apk','downloads/ChatFlow-0.4.24-build2193-arm64.apk','downloads/ChatFlow-0.4.25-build2194-arm64.apk']
RHP = 'fb8eb155-a1ae-4012-950c-c94d570e5efe'
OBJECT_ARN = 'arn:aws:s3:::starchat-installers-218022113852-sg/downloads/' + NAME
OLD_BYTES = 73139489
BUCKET = 'starchat-installers-218022113852-sg'
DIST = 'E30IR8IHK6PMXZ'
DIRECT = 'https://www.liuhetong888.com/downloads/' + NAME
CDN = 'https://d12fjr06o6tga5.cloudfront.net/downloads/' + NAME
SIGNER = '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff'
PRESERVED = ('src/admin-home.js', 'downloads/ios/manifest.plist',
             'src/download-redirect.js', 'src/download-network.js', 'src/download-network-selector.js')
SETTINGS = frozenset(('app_latest_version', 'app_latest_build', 'app_min_supported_build',
                     'app_update_notes', 'app_apk_url', 'app_ios_latest_version',
                     'app_ios_latest_build', 'app_ios_min_supported_build',
                     'app_ios_update_notes', 'app_ios_download_url'))

def sha(value):
    return hashlib.sha256(value).hexdigest()

def digest(path):
    with Path(path).open('rb') as source:
        result = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
        return result.hexdigest()

def read_json(path): return json.loads(Path(path).read_text(encoding='utf-8'))

def json_bytes(value): return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode('utf-8')

FROZEN_CLOUDFRONT = read_json(Path(__file__).with_name('sg-live-snapshot.json'))['cloudfront']
FROZEN_SETTINGS = read_json(Path(__file__).with_name('settings-before.json'))
FROZEN_STATIC = read_json(Path(__file__).with_name('static-baseline.json'))['files']
FROZEN_HOST = read_json(Path(__file__).with_name('hk-live-snapshot.json'))

def host_preservation(root):
    """Reject other ABI aliases and any running-container drift; never deploy services."""
    for name, target in FROZEN_HOST['aliases'].items():
        if name == 'latest-arm64.apk':
            continue
        alias = Path(root) / 'downloads' / name
        if not alias.is_symlink() or os.readlink(alias) != target:
            raise ValueError('preserved ABI alias drift: ' + name)
    names = subprocess.check_output(['docker', 'ps', '-q'], text=True).split()
    frozen = {x['name']: (x['id'], x['image'], x['restart_count'], x['started_at']) for x in FROZEN_HOST['runtime']}
    actual = json.loads(subprocess.check_output(['docker', 'inspect', *names]))
    current = {x['Name'].lstrip('/'): (x['Id'], x['Image'], x['RestartCount'], x['State']['StartedAt']) for x in actual}
    if current != frozen:
        raise ValueError('running-container identity drift; freeze again, never revert old images')

def settings_target(before):
    if set(before) != SETTINGS or any(not isinstance(v, str) or not v for v in before.values()):
        raise ValueError('exact nonempty ten-setting snapshot required')
    expected = {'app_latest_version': '0.4.44', 'app_latest_build': '2213',
                'app_min_supported_build': '3', 'app_apk_url': INSTALL,
                'app_ios_latest_version': '0.4.44', 'app_ios_latest_build': '2213',
                'app_ios_min_supported_build': '3', 'app_ios_download_url': IOS_INSTALL}
    if any(before[k] != v for k, v in expected.items()):
        raise ValueError('2213 Android / 2213 iOS / minimum / URL baseline drift')
    return before | {'app_latest_version': '0.4.45', 'app_latest_build': '2214', 'app_update_notes': NOTES}

def classify(before, after, current):
    if current == before: return 'before'
    if current == after: return 'complete'
    raise ValueError('unknown drift or partial state; inspect, do not replay')

def record(artifact_sha, artifact_bytes, signing_confirmed_by, source_commit=None, source_manifest_sha256=None):
    if (not isinstance(source_commit, str) or not re.fullmatch("[a-f0-9]{40}", source_commit)
            or source_commit == "0"*40 or not isinstance(source_manifest_sha256, str)
            or not re.fullmatch("[a-f0-9]{64}", source_manifest_sha256) or source_manifest_sha256 == "0"*64):
        raise ValueError("frozen source commit and source manifest SHA256 required")
    if (not isinstance(artifact_sha, str) or not re.fullmatch('[a-f0-9]{64}', artifact_sha)
            or type(artifact_bytes) is not int or artifact_bytes <= 0 or artifact_sha in (OLD_SHA, '0'*64)
            or not isinstance(signing_confirmed_by, str) or not signing_confirmed_by.strip()):
        raise ValueError('final signed artifact SHA/bytes and actual gate evidence required')
    return {'platform': 'android', 'version': '0.4.45', 'build': 2214,
            'artifact_sha256': artifact_sha, 'artifact_bytes': artifact_bytes,
            'artifact_url': DIRECT, 'cdn_url': CDN, 'network_selection': True,
            'signing_confirmed_by': signing_confirmed_by, 'source_commit': source_commit,
            'source_manifest_sha256': source_manifest_sha256,
            'delivery_mode': 'cloudfront-hk-origin',
            'signer_sha256': SIGNER, 'package': 'com.liuhetong.mobile', 'abi': 'arm64-v8a'}

def page_target(page):
    expected = b'data-cdn-host="d12fjr06o6tga5.cloudfront.net"'
    old = f'id="android-direct-download" href="/downloads/{OLD_NAME}" download'.encode()
    new = f'id="android-direct-download" href="/downloads/{NAME}" download'.encode()
    script = b'src="/src/download-redirect.js?v=2213-network"'
    if page.count(expected) != 1 or page.count(old) != 1 or page.count(script) != 1:
        raise ValueError('live Android network HTML baseline drift')
    if page.count(b'href="/downloads/latest-arm64.apk"') != 1:
        raise ValueError('native latest fallback drift')
    return page.replace(old, new).replace(script, b'src="/src/download-redirect.js?v=2214-network"')

def expected_policy(paths):
    return {'Version': '2012-10-17', 'Statement': [
        {'Sid': 'DenyInsecureTransport', 'Effect': 'Deny', 'Principal': '*', 'Action': 's3:*',
         'Resource': ['arn:aws:s3:::' + BUCKET, 'arn:aws:s3:::' + BUCKET + '/*'],
         'Condition': {'Bool': {'aws:SecureTransport': 'false'}}},
        {'Sid': 'AllowOnlyApprovedInstallerDistribution', 'Effect': 'Allow',
         'Principal': {'Service': 'cloudfront.amazonaws.com'}, 'Action': 's3:GetObject',
         'Resource': ['arn:aws:s3:::' + BUCKET + '/' + p for p in paths],
         'Condition': {'StringEquals': {'AWS:SourceArn': 'arn:aws:cloudfront::218022113852:distribution/' + DIST}}}]}

def policy_target(before):
    if before != expected_policy(OLD_PATHS): raise ValueError('existing bucket policy drift; no policy mutation permitted')
    return copy.deepcopy(before)

def cloudfront_target(before):
    baseline = FROZEN_CLOUDFRONT['DistributionConfig']
    items = baseline['CacheBehaviors']['Items']
    count = len(items)
    if baseline['CacheBehaviors']['Quantity'] != count:
        raise ValueError('frozen behavior inventory drift')
    if any(item['PathPattern'] == 'downloads/' + NAME for item in items):
        raise ValueError('target route already occupied in frozen baseline')
    old = [item for item in items if item['PathPattern'] == 'downloads/' + OLD_NAME]
    if len(old) != 1 or old[0]['TargetOriginId'] != 'installer-hong-kong':
        raise ValueError('previous exact HK route missing or drifted')
    new = copy.deepcopy(old[0]) | {'PathPattern': 'downloads/' + NAME}
    target = copy.deepcopy(baseline)
    # Existing immutable emoji behavior is retained byte-for-byte.
    target['CacheBehaviors'] = {'Quantity': count + 1, 'Items': copy.deepcopy(items) + [new]}
    if before != baseline and before != target:
        raise ValueError('exact frozen CloudFront baseline or derived target required')
    return target


def safe_file(root, name):
    root = Path(root).absolute(); relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts: raise ValueError('path escapes root')
    target = root / relative
    current = target
    while True:
        if current.is_symlink(): raise ValueError('symlink in release path')
        if current == root: break
        current = current.parent
    if not target.resolve().is_relative_to(root.resolve()): raise ValueError('resolved path escapes root')
    return target

def static_state(plan, root):
    for name, expected in plan['preserved'].items():
        if digest(safe_file(root, name)) != expected: raise ValueError('preserved live file drift: ' + name)
    current = {name: digest(safe_file(root, name)) for name in plan['static']}
    return classify({name: x['before'] for name, x in plan['static'].items()},
                    {name: x['after'] for name, x in plan['static'].items()}, current)

@contextmanager
def host_lock(root):
    import fcntl
    with (Path(root).parent / '.release-metadata.lock').open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield

def atomic(path, data):
    fd, temporary = tempfile.mkstemp(prefix='.2214-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as target:
            target.write(data); target.flush(); os.fsync(target.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)

def fresh_backup(backup, root):
    backup = Path(backup).absolute()
    if backup.exists() or backup.is_symlink() or backup.resolve().is_relative_to(Path(root).resolve()):
        raise ValueError('fresh private backup outside frontend required')
    # Do not follow redirected parent directories into the public root.
    for parent in backup.parents:
        if parent.is_symlink(): raise ValueError('symlink in backup path')
    backup.mkdir(parents=True, mode=0o700, exist_ok=False); os.chmod(backup, 0o700)
    return backup

def apply_static(plan, root, stage, backup, *, lock=host_lock):
    with lock(root):
        if static_state(plan, root) == 'complete': return 'complete'
        data = {name: safe_file(stage, name).read_bytes() for name in plan['static']}
        if any(sha(value) != plan['static'][name]['after'] for name, value in data.items()):
            raise ValueError('staged payload SHA mismatch')
        old = {name: safe_file(root, name).read_bytes() for name in plan['static']}
        if any(sha(value) != plan['static'][name]['before'] for name, value in old.items()):
            raise ValueError('original bytes differ from exact before state')
        backup = fresh_backup(backup, root)
        for name in plan['static']:
            target = backup / name; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(old[name])
        (backup / 'plan.json').write_bytes(json_bytes(plan))
        written = []
        try:
            for name, value in data.items():
                if digest(safe_file(root, name)) != plan['static'][name]['before']:
                    raise ValueError('CAS failed: ' + name)
                atomic(safe_file(root, name), value); written.append(name)
            if static_state(plan, root) != 'complete': raise ValueError('static readback mismatch')
        except Exception:
            for name in reversed(written):
                if digest(safe_file(root, name)) == plan['static'][name]['after']:
                    # Use the same verified original buffer; a damaged backup
                    # cannot become public content during exception recovery.
                    atomic(safe_file(root, name), old[name])
            raise
        return 'published'

def rollback_static(plan, root, backup, *, lock=host_lock):
    with lock(root):
        if static_state(plan, root) != 'complete': raise ValueError('rollback requires exact completed state')
        old = {name: (Path(backup) / name).read_bytes() for name in plan['static']}
        if any(sha(value) != plan['static'][name]['before'] for name, value in old.items()):
            raise ValueError('backup differs from exact original')
        for name, data in old.items():
            if digest(safe_file(root, name)) != plan['static'][name]['after']: raise ValueError('rollback CAS drift')
            atomic(safe_file(root, name), data)

def prepare(args):
    r = record(args.sha256, args.bytes, args.signing_confirmed_by, args.source_commit, args.source_manifest_sha256)
    snapshot = args.snapshot
    settings = read_json(args.settings); target_settings = settings_target(settings)
    if settings != FROZEN_SETTINGS: raise ValueError('exact frozen ten settings required')
    for name, identity in FROZEN_STATIC.items():
        path = safe_file(snapshot, name)
        if digest(path) != identity['sha256'] or path.stat().st_size != identity['bytes']:
            raise ValueError('frozen seven-file snapshot drift: ' + name)
    cf = read_json(args.cloudfront); policy = read_json(args.policy)
    if cf != FROZEN_CLOUDFRONT: raise ValueError('exact frozen CloudFront config and ETag required')
    cf_after = cloudfront_target(cf['DistributionConfig']); policy_after = policy_target(policy)
    old_registry = read_json(safe_file(snapshot, 'downloads/android-release.json'))
    expected_registry = {'platform': 'android', 'version': '0.4.44', 'build': 2213,
        'artifact_bytes': OLD_BYTES, 'sha256': OLD_SHA,
        'cdn_url': CDN.replace(NAME, OLD_NAME), 'direct_url': DIRECT.replace(NAME, OLD_NAME)}
    if old_registry != expected_registry: raise ValueError('2213 live registry identity drift')
    targets = {'download.html': page_target(safe_file(snapshot, 'download.html').read_bytes()),
               'downloads/android-release.json': json_bytes({'platform': 'android', 'version': '0.4.45',
                   'build': 2214, 'artifact_bytes': args.bytes, 'sha256': args.sha256, 'cdn_url': CDN, 'direct_url': DIRECT})}
    preserved = {name: digest(safe_file(snapshot, name)) for name in PRESERVED}
    home = safe_file(snapshot, 'src/admin-home.js').read_bytes()
    if b'/download?platform=android&install=1' not in home: raise ValueError('existing Android homepage network bridge required')
    r['network_assets'] = {name.removeprefix('src/'): preserved[name] for name in PRESERVED if name.startswith('src/download-')}
    r['deployment'] = {'static': {name: {'before': digest(safe_file(snapshot, name)), 'after': sha(value)} for name, value in targets.items()},
        'preserved': preserved, 'settings_before': settings, 'settings_after': target_settings,
        'cloudfront_before': cf, 'cloudfront_after': cf_after,
        'bucket_policy_before': policy, 'bucket_policy_after': policy_after,
        'old_artifact': {'name': OLD_NAME, 'sha256': OLD_SHA, 'bytes': OLD_BYTES},
        'update_notes': NOTES}
    output = fresh_backup(args.output, snapshot)
    for name, data in targets.items():
        target = output / 'staged' / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
    for name, value in (('release.json', r), ('cloudfront-target.json', cf_after), ('bucket-policy-target.json', policy_after)):
        (output / name).write_bytes(json_bytes(value))
    return {'status': 'PREPARED_OFFLINE', 'release': str(output / 'release.json'), 'sha256': digest(output / 'release.json')}

def validate_release(r):
    core = record(r['artifact_sha256'], r['artifact_bytes'], r['signing_confirmed_by'], r.get('source_commit'), r.get('source_manifest_sha256'))
    if any(r.get(k) != v for k, v in core.items()): raise ValueError('release identity drift')
    p = r['deployment']
    if p['cloudfront_before'] != FROZEN_CLOUDFRONT: raise ValueError('frozen CloudFront baseline identity drift')
    if p['settings_before'] != FROZEN_SETTINGS: raise ValueError('frozen settings baseline drift')
    if settings_target(p['settings_before']) != p['settings_after']: raise ValueError('settings target drift')
    if set(p['static']) != {'download.html', 'downloads/android-release.json'} or set(p['preserved']) != set(PRESERVED):
        raise ValueError('release static allowlist drift')
    page = Path(__file__).parent / 'hk-snapshot' / 'download.html'
    if digest(page) != FROZEN_STATIC['download.html']['sha256']:
        raise ValueError('frozen page input identity drift')
    expected_payloads = {'download.html': page_target(page.read_bytes()),
        'downloads/android-release.json': json_bytes({'platform':'android', 'version':'0.4.45', 'build':2214,
            'artifact_bytes':r['artifact_bytes'], 'sha256':r['artifact_sha256'], 'cdn_url':CDN, 'direct_url':DIRECT})}
    expected_static = {name: {'before':FROZEN_STATIC[name]['sha256'], 'after':sha(payload)}
                       for name,payload in expected_payloads.items()}
    if p['static'] != expected_static: raise ValueError('frozen static before or derived target drift')
    if p['preserved'] != {name:FROZEN_STATIC[name]['sha256'] for name in PRESERVED}:
        raise ValueError('frozen preserved files identity drift')
    if p['old_artifact'] != {'name':OLD_NAME, 'sha256':OLD_SHA, 'bytes':OLD_BYTES} or p['update_notes'] != NOTES:
        raise ValueError('old fallback artifact or notes drift')
    if r['network_assets'] != {name.removeprefix('src/'): p['preserved'][name] for name in PRESERVED if name.startswith('src/download-')}:
        raise ValueError('network asset handoff drift')
    if cloudfront_target(p['cloudfront_before']['DistributionConfig']) != p['cloudfront_after']: raise ValueError('CloudFront target drift')
    if policy_target(p['bucket_policy_before']) != p['bucket_policy_after']: raise ValueError('bucket policy target drift')

def db(mode, r, trace=None):
    payload = {'mode': mode, 'expected': r['deployment']['settings_before'],
               'after': r['deployment']['settings_after'], 'trace': trace}
    code = Path(__file__).with_name('settings_2214.py').read_bytes()
    result = subprocess.check_output(['docker', 'exec', '-i', '-w', '/opt/business-api',
        'starchat-business-api-1', 'python3', '-', json.dumps(payload)], input=code)
    return json.loads(result)

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs): return None

def public_check(r, *, completed):
    opener = urllib.request.build_opener(NoRedirect())
    for url in (DIRECT, CDN):
        with opener.open(urllib.request.Request(url, method='HEAD'), timeout=20) as response:
            if response.status != 200 or response.url != url or int(response.headers.get('Content-Length', '-1')) != r['artifact_bytes']:
                raise ValueError('public APK HEAD mismatch')
            if response.headers.get('Content-Type', '').split(';')[0].strip() not in ('application/vnd.android.package-archive', 'application/octet-stream'):
                raise ValueError('public APK MIME mismatch')
    if completed:
        expected = {name: entry['after'] for name, entry in r['deployment']['static'].items()}
        expected.update({'src/' + name: value for name, value in r['network_assets'].items()})
        for name, expected_sha in expected.items():
            url = 'https://www.liuhetong888.com/' + ('download' if name == 'download.html' else name)
            with opener.open(urllib.request.Request(url, headers={'Cache-Control': 'no-cache'}), timeout=20) as response:
                data = response.read(262145)
                if response.status != 200 or response.url != url or len(data) > 262144 or sha(data) != expected_sha:
                    raise ValueError('public release metadata mismatch')
                mime = response.headers.get('Content-Type', '')
                if name.endswith('.json') and ('application/json' not in mime or 'no-store' not in response.headers.get('Cache-Control', '')):
                    raise ValueError('registry MIME/no-store mismatch')
                if name.endswith('.js') and 'javascript' not in mime: raise ValueError('network script MIME mismatch')
                if name.endswith('.html') and 'text/html' not in mime: raise ValueError('download page MIME mismatch')

def check(r, root):
    validate_release(r)
    host_preservation(root)
    for name, expected_sha, size in ((OLD_NAME, OLD_SHA, OLD_BYTES), (NAME, r['artifact_sha256'], r['artifact_bytes'])):
        source = safe_file(root, 'downloads/' + name)
        if source.stat().st_size != size or digest(source) != expected_sha: raise ValueError('server APK identity mismatch: ' + name)
    alias = Path(root) / 'downloads/latest-arm64.apk'
    if not alias.is_symlink() or os.readlink(alias) not in (OLD_NAME, NAME): raise ValueError('latest alias drift')
    static = static_state(r['deployment'], root)
    settings = db('inspect', r)
    setting_state = classify(r['deployment']['settings_before'], r['deployment']['settings_after'], settings)
    public_check(r, completed=static == 'complete')
    return {'static': static, 'settings': setting_state, 'alias': os.readlink(alias), 'live_settings': settings}

def publish(r, root, stage, backup, trace):
    if not trace or not re.fullmatch('[A-Za-z0-9_.:-]{8,100}', trace): raise ValueError('unique audit trace required')
    backup = Path(backup)
    if not backup.absolute().is_relative_to(Path('/opt/starchat/docs/verification/artifacts')):
        raise ValueError('production backup must be under private verification root')
    with host_lock(root):
        before = check(r, root)
        if before['static'] == before['settings'] == 'complete':
            if before['alias'] != NAME: raise ValueError('completed metadata requires exact new alias')
            return {'status': 'ALREADY_COMPLETE', **before}
        if before['static'] != 'before' or before['settings'] != 'before': raise ValueError('partial publication; inspect prior backup/trace')
        if before['alias'] != NAME: raise ValueError('verified new binary alias required before publication')
        from contextlib import nullcontext
        apply_static(r['deployment'], root, stage, backup, lock=lambda _: nullcontext())
        (backup / 'release.json').write_bytes(json_bytes(r))
        (backup / 'settings-before.json').write_bytes(json_bytes(before['live_settings']))
        try:
            public_check(r, completed=True)
        except Exception:
            rollback_static(r['deployment'], root, backup, lock=lambda _: nullcontext())
            raise
        try:
            after = db('apply', r, trace)
            if after != r['deployment']['settings_after']: raise ValueError('settings readback mismatch')
            if check(r, root)['settings'] != 'complete': raise ValueError('final readback mismatch')
        except Exception:
            (backup / 'outcome-unknown.json').write_bytes(json_bytes({'trace': trace, 'action': 'Inspect ten settings and audit trace; do not replay or roll back automatically.'}))
            raise
        (backup / 'result.json').write_bytes(json_bytes({'status': 'PUBLISH_PASS', 'trace': trace, 'settings_after': after}))
        return {'status': 'PUBLISH_PASS', 'trace': trace, 'backup': str(backup)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    p = sub.add_parser('prepare')
    for name in ('snapshot', 'settings', 'cloudfront', 'policy', 'output'): p.add_argument('--' + name, type=Path, required=True)
    p.add_argument('--source-commit', required=True); p.add_argument('--source-manifest-sha256', required=True)
    p.add_argument('--sha256', required=True); p.add_argument('--bytes', type=int, required=True); p.add_argument('--signing-confirmed-by', required=True)
    for mode in ('check', 'publish'):
        p = sub.add_parser(mode); p.add_argument('record', type=Path); p.add_argument('--root', type=Path, default=Path('/opt/starchat/frontend'))
        if mode == 'publish':
            p.add_argument('--backup', type=Path, required=True); p.add_argument('--trace', required=True)
    args = parser.parse_args()
    if args.mode == 'prepare': result = prepare(args)
    else:
        r = read_json(args.record)
        result = check(r, args.root) if args.mode == 'check' else publish(r, args.root, args.record.parent / 'staged', args.backup, args.trace)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))

if __name__ == '__main__': main()
