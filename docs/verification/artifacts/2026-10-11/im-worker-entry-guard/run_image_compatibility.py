"""Temporary verification only: isolated final images; never switches services."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
from uuid import uuid4

ROOT = Path(__file__).resolve().parent
IMAGES = {
    'old_old': 'sha256:18a88c4dde6e09fb75122aef1f011fd11c7a0421e61559b0548ed78c1b8b3ecf',
    'new_new': 'sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a',
    'new_old': 'sha256:13f3c67b2f84b09a659af16a5308917c3358071f1fada9cb66e7c9af6b2d9cd7',
    'api': 'sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3',
}
HASHES = {
    'business_refresh_image_probe.py': '2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15',
    'business_release_guard.py': '46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b',
}
for filename, expected in HASHES.items():
    assert hashlib.sha256((ROOT / filename).read_bytes()).hexdigest() == expected
spec = importlib.util.spec_from_file_location('guard', ROOT / 'business_release_guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
results = []
real_run = subprocess.run
image_runs = []
def recorded_run(command, **kwargs):
    result = real_run(command, **kwargs)
    if command[:2] == ['docker', 'run']:
        image_runs.append({'argv': command, 'exit_code': result.returncode,
                           'proof': json.loads(result.stdout.splitlines()[-1])})
    return result
guard.subprocess.run = recorded_run
for label, image in IMAGES.items():
    role = 'api' if label == 'api' else 'worker'
    expected = label != 'new_old'
    try:
        proof = guard.verify_image(image, role)
        passed = True
    except ValueError:
        proof = {'passed': False}
        passed = False
    assert passed == expected, label
    results.append({'label': label, 'image': image, 'expected_passed': expected,
                    'actual_guard': proof, 'actual_run': image_runs[-1]})
guard.subprocess.run = real_run

# Verify default entrypoint imports before the probe has adjusted any paths.
# -c retains image cwd/sys.path[0]; no PYTHONPATH, production env or data mount.
code = """import json, os, main, worker
import app.core.outbox as outbox
assert not os.environ.get('PYTHONPATH')
assert os.getcwd() == '/opt/business-worker/app'
assert main.__file__ == '/opt/business-worker/app/main.py'
assert worker.__file__ == '/opt/business-worker/app/worker.py'
assert outbox.__file__ == '/usr/local/lib/python3.12/site-packages/app/core/outbox.py'
assert main.Worker is worker.Worker and main.OutboxConsumer is outbox.OutboxConsumer
try:
    main.Worker(consumer=main.OutboxConsumer(None), handlers={}, worker_id='isolated-default-entry')
except TypeError:
    print(json.dumps({'passed': False, 'reason': 'INCOMPATIBLE_ENTRY_COMPOSITION'}))
    raise SystemExit(1)
print(json.dumps({'passed': True, 'default_imports': True}))
"""
for label in ('old_old', 'new_new', 'new_old'):
    name = 'starchat-entry-proof-' + uuid4().hex
    command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
               '--memory', '512m', '--cpus', '1', '--pids-limit', '128',
               '--tmpfs', '/tmp:rw,nosuid,size=32m', '-e', 'PYTHONDONTWRITEBYTECODE=1',
               '--entrypoint', 'python', IMAGES[label], '-c', code]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    finally:
        subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)
    assert result.returncode == (1 if label == 'new_old' else 0), label
    results.append({'label': 'default_' + label, 'image': IMAGES[label],
                    'argv': command, 'exit_code': result.returncode,
                    'proof': json.loads(result.stdout.splitlines()[-1])})

# The public probe intentionally emits only passed=false. Pin the rejected
# candidate's exact failure stage separately without exposing arbitrary errors.
diagnostic = """import json, runpy, traceback
probe = runpy.run_path('/protocol-probe.py')
try:
    probe['verify_worker']()
except TypeError as error:
    assert str(error) == 'consumer requires generation-fenced claim completion: mark_claim_succeeded'
    frames = traceback.extract_tb(error.__traceback__)
    assert frames[-2].name == 'verify_worker' and frames[-1].name == '__init__'
    assert frames[-1].filename == '/opt/business-worker/app/worker.py'
    print(json.dumps({'failed_check': 'worker_entry_composition', 'expected_contract_error': True}))
else:
    raise AssertionError('incompatible composition was accepted')
"""
name = 'starchat-entry-diagnostic-' + uuid4().hex
command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
           '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
           '--memory', '512m', '--cpus', '1', '--pids-limit', '128',
           '--tmpfs', '/tmp:rw,nosuid,size=32m', '-e', 'PYTHONDONTWRITEBYTECODE=1',
           '-v', str(ROOT / 'business_refresh_image_probe.py') + ':/protocol-probe.py:ro',
           '--entrypoint', 'python', IMAGES['new_old'], '-c', diagnostic]
try:
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
finally:
    subprocess.run(['docker', 'rm', '-f', name], capture_output=True, timeout=15)
assert result.returncode == 0
results.append({'label': 'new_old_failure_stage', 'image': IMAGES['new_old'],
                'argv': command, 'exit_code': result.returncode,
                'proof': json.loads(result.stdout.splitlines()[-1])})
print(json.dumps({'input_sha256': HASHES, 'results': results}, indent=2))
