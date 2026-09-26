"""Install host ops guard/timer; never change or restart business containers."""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from uuid import uuid4

FILES = ('business_refresh_image_probe.py', 'business_release_guard.py', 'refresh_watchdog.py', 'refresh_alert_email.py')
OPS = Path('/opt/starchat/ops/refresh-guards')
MARKER = '# REFRESH_PROTOCOL_GUARD_V1'
SERVICE = '''[Unit]
Description=StarChat refresh protocol and error-rate watch
After=docker.service network-online.target
OnFailure=starchat-refresh-watch-failure.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/starchat/ops/refresh-guards/refresh_watchdog.py
TimeoutStartSec=60
UMask=0077
StateDirectory=starchat-refresh-watch
StateDirectoryMode=0700
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/starchat-refresh-watch
MemoryMax=192M
'''
FAILURE = SERVICE.replace('OnFailure=starchat-refresh-watch-failure.service\n', '').replace(
    'refresh_watchdog.py\n', 'refresh_watchdog.py --failure-only\n')
TIMER = '''[Unit]
Description=Check StarChat refresh every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5
Unit=starchat-refresh-watch.service

[Install]
WantedBy=timers.target
'''


def protect_release(source):
    if MARKER in source:
        return source
    rollback = 'def rollback():\n'
    deploy = "elif mode == 'deploy':\n"
    if source.count(rollback) != 1 or source.count(deploy) != 1:
        raise ValueError('Unknown release entry points')
    compose_path = "str(ROOT / (version + '-' + role + '-private.json'))"
    if source.count(compose_path) != 1:
        raise ValueError('Unknown Compose dispatcher')
    source = source.replace(compose_path, "str(GUARDED_COMPOSE[(role, version)] if mode in ('deploy', 'rollback') else ROOT / (version + '-' + role + '-private.json'))")
    helper = '''# REFRESH_PROTOCOL_GUARD_V1
GUARDED_COMPOSE = {}


def enforce_refresh_protocol(version):
    command = ['python3', '/opt/starchat/ops/refresh-guards/business_release_guard.py', 'freeze',
               '--release-dir', str(ROOT), '--version', version]
    frozen = json.loads(subprocess.check_output(command, text=True))
    for role, path in frozen['configs'].items():
        GUARDED_COMPOSE[(role, version)] = Path(path)


'''
    source = source.replace(rollback, helper+rollback+"    enforce_refresh_protocol('rollback')\n", 1)
    source = source.replace(deploy, deploy+"    enforce_refresh_protocol('candidate')\n", 1)
    ast.parse(source)
    return source


def install(release_script, expected_sha):
    if os.geteuid() != 0:
        raise ValueError('Root required for systemd installation')
    release_script = release_script.resolve(strict=True)
    if release_script.parent.parent != Path('/opt/starchat/releases') or release_script.name != 'release.py':
        raise ValueError('Explicit release directory required')
    original = release_script.read_bytes()
    if hashlib.sha256(original).hexdigest() != expected_sha:
        raise ValueError('Release entry drift; inspect before patching')
    revised = protect_release(original.decode('utf8'))
    for name in FILES:
        ast.parse(Path(__file__).with_name(name).read_text(encoding='utf8'))
    OPS.mkdir(parents=True, mode=0o700, exist_ok=True)
    backup = Path(__file__).parent/('install-backup-'+uuid4().hex)
    backup.mkdir(mode=0o700, exist_ok=False)
    records = {}
    targets = [(OPS/name, Path(__file__).with_name(name).read_bytes()) for name in FILES]
    targets += [(Path('/etc/systemd/system')/name, body.encode()) for name,body in (
        ('starchat-refresh-watch.service',SERVICE), ('starchat-refresh-watch-failure.service',FAILURE),
        ('starchat-refresh-watch.timer',TIMER))]
    targets.append((release_script,revised.encode()))
    for index,(path,content) in enumerate(targets):
        records[str(path)] = {'existed':path.exists(), 'new_sha256':hashlib.sha256(content).hexdigest(), 'backup':str(index),
            'old_sha256':hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None,
            'old_mode':path.stat().st_mode & 0o777 if path.exists() else None}
        if path.exists():
            shutil.copy2(path,backup/str(index))
            with (backup/str(index)).open('rb') as stream:
                os.fsync(stream.fileno())
    prior = {kind:subprocess.run(['systemctl',kind,'starchat-refresh-watch.timer'],capture_output=True,text=True).stdout.strip()
             for kind in ('is-enabled','is-active')}
    # All backup bytes and mappings are durable BEFORE the first target overwrite.
    with (backup/'manifest.json').open('w') as stream:
        json.dump({'files':records,'timer':prior},stream,indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    directory_fd = os.open(backup,os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    try:
        for path,content in targets:
            tmp=path.with_suffix(path.suffix+'.refresh-new')
            tmp.write_bytes(content)
            os.chmod(tmp,0o644 if path.parent == Path('/etc/systemd/system') else 0o600)
            os.replace(tmp,path)
        subprocess.run(['systemd-analyze','verify','/etc/systemd/system/starchat-refresh-watch.service',
                        '/etc/systemd/system/starchat-refresh-watch-failure.service','/etc/systemd/system/starchat-refresh-watch.timer'],check=True)
        subprocess.run(['systemctl','daemon-reload'],check=True)
        subprocess.run(['systemctl','enable','--now','starchat-refresh-watch.timer'],check=True)
        subprocess.run(['systemctl','start','starchat-refresh-watch.service'],check=True)
    except Exception:
        restore(backup)
        raise
    print(json.dumps({'installed':True,'guarded_release':str(release_script),'backup':str(backup)}))


def restore(backup):
    manifest=json.loads((backup/'manifest.json').read_text())
    for name,record in manifest['files'].items():
        path=Path(name)
        current=hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
        if current not in (record['old_sha256'],record['new_sha256']):
            raise ValueError('Later file drift prevents restoration')
        if record['existed'] and hashlib.sha256((backup/record['backup']).read_bytes()).hexdigest() != record['old_sha256']:
            raise ValueError('Backup corrupted')
    subprocess.run(['systemctl','disable','--now','starchat-refresh-watch.timer'],capture_output=True)
    subprocess.run(['systemctl','stop','starchat-refresh-watch.service','starchat-refresh-watch-failure.service'],capture_output=True)
    for name,record in manifest['files'].items():
        path=Path(name)
        if record['existed']:
            tmp=path.with_suffix(path.suffix+'.restore-new')
            shutil.copyfile(backup/record['backup'],tmp)
            os.chmod(tmp,record['old_mode'])
            os.replace(tmp,path)
        elif path.exists():
            path.unlink()
    subprocess.run(['systemctl','daemon-reload'],check=True)
    if manifest['timer']['is-enabled']=='enabled':
        subprocess.run(['systemctl','enable','starchat-refresh-watch.timer'],check=True)
    if manifest['timer']['is-active']=='active':
        subprocess.run(['systemctl','start','starchat-refresh-watch.timer'],check=True)
    print(json.dumps({'restored':True,'backup':str(backup)}))


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--release-script',type=Path)
    parser.add_argument('--expected-sha')
    parser.add_argument('--restore-backup',type=Path)
    args=parser.parse_args()
    if args.restore_backup:
        restore(args.restore_backup)
    else:
        install(args.release_script,args.expected_sha)
