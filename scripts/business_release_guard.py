"""One fail-closed final-image gate for deployment AND rollback."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from uuid import uuid4


def validate_image(image):
    if not isinstance(image, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        raise ValueError('Immutable local image digest required')
    return image


def check_then_apply(images, checker, apply):
    for image in dict.fromkeys(images):
        checker(validate_image(image))
    return apply()


def escape_interpolation(value):
    if isinstance(value,str):
        return value.replace('$','$$')
    if isinstance(value,list):
        return [escape_interpolation(item) for item in value]
    if isinstance(value,dict):
        return {key:escape_interpolation(item) for key,item in value.items()}
    return value


def verify_image(image):
    validate_image(image)
    probe = Path(__file__).with_name('business_refresh_image_probe.py').resolve()
    name = 'starchat-protocol-' + uuid4().hex
    try:
        result = subprocess.run(['docker', 'run', '--name', name, '--rm', '--network', 'none', '--read-only',
        '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--memory', '512m', '--cpus', '1',
        '--pids-limit', '128', '--tmpfs', '/tmp:rw,nosuid,size=128m',
        '-e', 'PYTHONDONTWRITEBYTECODE=1', '-e', 'BUSINESS_ENVIRONMENT=test',
        '-e', 'BUSINESS_DATABASE_URL=sqlite+pysqlite:///:memory:',
        '-v', str(probe)+':/protocol-probe.py:ro', '--entrypoint', 'python', image, '/protocol-probe.py'],
            capture_output=True, text=True, timeout=90)
    finally:
        # A timed-out docker client does not stop its container automatically.
        subprocess.run(['docker','rm','-f',name], capture_output=True, timeout=15)
    if result.returncode:
        raise ValueError('Final image protocol gate rejected '+image)
    proof = json.loads(result.stdout.splitlines()[-1])
    if proof.get('passed') is not True or proof.get('protocol') != 'mobile-refresh-recovery-v1' or len(proof.get('checks', [])) < 9:
        raise ValueError('Incomplete image protocol evidence')
    return {'image':image, **proof}


def switch(compose_files, services, operation):
    if not services or set(services) - {'business-api', 'business-worker'}:
        raise ValueError('Only business-api/business-worker may be switched')
    command = ['docker', 'compose', '-p', 'starchat']
    for file in compose_files:
        command += ['-f', str(Path(file).resolve())]
    rendered = subprocess.run(command+['config', '--format', 'json'], capture_output=True, text=True, check=True, timeout=30)
    config = json.loads(rendered.stdout)
    config['services'] = {name:config['services'][name] for name in services}
    images = [s['image'] for s in config['services'].values()]
    proofs = []
    def check(image):
        proofs.append(verify_image(image))
    def apply():
        # Freeze resolved config after validation: no mutable tags or changed input files.
        # Compose records this path in container labels: keep it for future recovery.
        folder = tempfile.mkdtemp(prefix='guarded-', dir='/opt/starchat/releases')
        os.chmod(folder, 0o700)
        path = Path(folder)/'compose.json'
        path.write_text(json.dumps(escape_interpolation(config)), encoding='utf8')
        os.chmod(path, 0o600)
        subprocess.run(['docker', 'compose', '-p', 'starchat', '-f', str(path), 'up', '-d',
            '--no-deps', '--pull', 'never', '--no-build', *services], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
        return {'operation':operation, 'proofs':proofs, 'switched':services, 'snapshot':str(path)}
    return check_then_apply(images, check, apply)


def freeze_release(root, version):
    """Validate the actual Compose inputs and bind existing release helpers to them."""
    root = Path(root).resolve(strict=True)
    if version not in ('candidate','rollback'):
        raise ValueError('Invalid version')
    mapping = 'images.json' if version == 'candidate' else 'rollback-images.json'
    expected = json.loads((root/mapping).read_text())
    if not isinstance(expected,dict) or set(expected) != {'api','worker'}:
        raise ValueError('Invalid roles')
    configs = {}
    for role,image in expected.items():
        validate_image(image)
        result = subprocess.run(['docker','compose','-p','starchat','-f',str(root/(version+'-'+role+'-private.json')),
            'config','--format','json'], capture_output=True,text=True,check=True,timeout=30)
        config = json.loads(result.stdout)
        service = 'business-'+role
        if set(config['services']) != {service} or config['services'][service].get('image') != image:
            raise ValueError('Compose/image evidence mismatch')
        configs[role] = config
    proofs = []
    def check(image):
        proofs.append(verify_image(image))
    def freeze():
        folder = Path(tempfile.mkdtemp(prefix='guarded-'+version+'-',dir=root))
        os.chmod(folder,0o700)
        paths = {}
        for role,config in configs.items():
            path = folder/(role+'.json')
            path.write_text(json.dumps(escape_interpolation(config)),encoding='utf8')
            os.chmod(path,0o600)
            paths[role] = str(path)
        return {'configs':paths,'proofs':proofs}
    return check_then_apply(list(expected.values()),check,freeze)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('operation', choices=['check', 'deploy', 'rollback', 'freeze'])
    parser.add_argument('--image', action='append', default=[])
    parser.add_argument('--compose', action='append', default=[])
    parser.add_argument('--service', action='append', default=[])
    parser.add_argument('--release-dir')
    parser.add_argument('--version',choices=['candidate','rollback'])
    args = parser.parse_args()
    try:
        if args.operation == 'check':
            if not args.image:
                raise ValueError('No images')
            result = [verify_image(image) for image in args.image]
        elif args.operation == 'freeze':
            result = freeze_release(args.release_dir,args.version)
        else:
            result = switch(args.compose, args.service, args.operation)
        print(json.dumps(result))
    except Exception:
        print(json.dumps({'passed':False, 'reason':'RELEASE_PROTOCOL_GATE_FAILED'}))
        raise SystemExit(1)


if __name__ == '__main__':
    main()
