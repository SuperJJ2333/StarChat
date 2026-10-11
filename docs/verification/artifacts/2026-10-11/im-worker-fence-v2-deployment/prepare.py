"""Freeze live API/worker/Getui and build exact reviewed source overlays; no deploy."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path('/opt/starchat/releases/im-worker-fence-v2-20261011')
PRIVATE = ROOT / 'private'
os.umask(0o077)
SPECS = {'api': ('starchat-business-api-1', 'sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3', {}), 'worker': ('starchat-business-worker-1', 'sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf', {'worker.py': ('/opt/business-worker/app/worker.py', '96f67aa7ed95a98b91650cf487033dcf8237564ac4ce17a899ded05989a2d72d', 'f88387d6c957f774b6c137f786b82235b74e8a5cf26a5e282259c7da94eb2299'), 'outbox.py': ('/usr/local/lib/python3.12/site-packages/app/core/outbox.py', 'ed8b556ae4ba19e18e1a098a042b6ef7ce7ce868e989275f89844fef58b61e27', 'a2e606116fef84986d7d4781090d792f6d8d6f0785b8679db3299160a660f680'), 'outbox-source.py': ('/opt/business-api/app/core/outbox.py', 'ed8b556ae4ba19e18e1a098a042b6ef7ce7ce868e989275f89844fef58b61e27', 'a2e606116fef84986d7d4781090d792f6d8d6f0785b8679db3299160a660f680')})}


def output(*args):
    return subprocess.check_output(args, text=True, timeout=30)


def escape(value):
    if isinstance(value, str): return value.replace('$', '$$')
    if isinstance(value, list): return [escape(item) for item in value]
    if isinstance(value, dict): return {key: escape(item) for key, item in value.items()}
    return value


assert not (ROOT / 'services-manifest.json').exists(), 'already prepared'
manifest = {'stage': 'prepared_not_deployed', 'roles': {}}
for role, (name, base_image, files) in SPECS.items():
    live = json.loads(output('docker', 'inspect', name))[0]
    assert live['Image'] == base_image, 'image drift'
    (PRIVATE / (role + '-inspect.json')).write_text(json.dumps(live))
    labels = live['Config']['Labels']
    source_paths = labels['com.docker.compose.project.config_files'].split(',')
    command = ['docker', 'compose', '-p', 'starchat']
    for path in source_paths: command.extend(['-f', path])
    rendered = subprocess.run(command + ['config', '--format', 'json'], text=True, capture_output=True, timeout=30)
    (PRIVATE / (role + '-render-errors.txt')).write_text(rendered.stderr)
    assert rendered.returncode == 0, 'live Compose rendering failed'
    config = json.loads(rendered.stdout)
    service = labels['com.docker.compose.service']
    selected = config['services'][service]
    actual_env = {}
    for value in live['Config'].get('Env', []):
        key, separator, content = value.partition('=')
        actual_env[key] = content if separator else None
    assert all((str(value) if value is not None else None) == actual_env.get(key)
               for key, value in selected.get('environment', {}).items()), 'environment drift'
    # Freeze existing resolved settings, retaining only this role's service.
    config['services'] = {service: selected}
    selected.pop('depends_on', None)
    selected.pop('build', None)
    selected['image'] = base_image
    old = copy.deepcopy(config)
    for filename, (destination, old_sha, new_sha) in files.items():
        actual_sha = output('docker', 'exec', name, 'python', '-c',
                            f'import hashlib;print(hashlib.sha256(open({destination!r},"rb").read()).hexdigest())').strip()
        assert actual_sha == old_sha, 'runtime source drift'
        assert hashlib.sha256((ROOT / role / filename).read_bytes()).hexdigest() == new_sha, 'payload drift'
    candidate_image = base_image
    if files:
        folder = ROOT / role
        (folder / 'Dockerfile').write_text('FROM ' + base_image + '\n' + ''.join(
            'COPY ' + filename + ' ' + values[0] + '\n' for filename, values in files.items()))
        tag = 'starchat/' + role + ':im-worker-fence-v2-20261011'
        with (ROOT / (role + '-build.log')).open('w') as log:
            subprocess.run(['docker', 'build', '--network=none', '--pull=false', '-t', tag, str(folder)],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
        candidate_image = output('docker', 'image', 'inspect', '--format', '{{.Id}}', tag).strip()
    selected['image'] = candidate_image
    for kind, content in [('rollback', old), ('candidate', config)]:
        (PRIVATE / (role + '-' + kind + '.json')).write_text(json.dumps(escape(content)))
    manifest['roles'][role] = {'name': name, 'service': service, 'id': live['Id'], 'old_image': base_image,
       'candidate_image': candidate_image, 'files': files,
       'source_hashes': {path: hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in source_paths},
       'config_hashes': {kind: hashlib.sha256((PRIVATE / (role + '-' + kind + '.json')).read_bytes()).hexdigest()
                         for kind in ('rollback', 'candidate')}}
(PRIVATE / 'services-before-container-ids.txt').write_text(output('docker', 'ps', '-a', '--no-trunc', '--format', '{{.Names}} {{.ID}}'))
(ROOT / 'services-manifest.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest))
