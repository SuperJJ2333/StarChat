"""Actual immutable image/default-import evidence. Never use production data."""
import hashlib
import json
import re
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from uuid import uuid4

ROOT = Path('/opt/starchat/releases/im-worker-active-lease-20261011')
TOOLS_SHA = '71a0a7c69a9027d17445d07808dd09e01919b19c61dad06e34dda3d2e6b380ee'
TESTS = ['test_worker_active_lease.py', 'test_published_worker_entrypoint.py',
         'test_worker_claim_fencing.py', 'test_worker_lease_window.py']


def isolated_check(image, code, mounts):
    name = 'starchat-active-lease-probe-' + uuid4().hex
    argv = ['docker','run','--rm','--name',name,'--network','none','--read-only',
            '--cap-drop','ALL','--security-opt','no-new-privileges',
            '--memory','384m','--cpus','1','--pids-limit','128',
            '--tmpfs','/tmp:rw,size=64m','-e','PYTHONDONTWRITEBYTECODE=1',
            '-e','PYTEST_DISABLE_PLUGIN_AUTOLOAD=1']
    for source, target in mounts:
        argv += ['-v', str(ROOT/source) + ':' + target + ':ro']
    argv += ['--entrypoint','python',image,'-c',code]
    result = {'argv': argv, 'container': name}
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=90)
        result.update(exit_code=completed.returncode, stdout=completed.stdout, stderr=completed.stderr)
    except subprocess.TimeoutExpired:
        result.update(exit_code=124, failure='isolated probe timeout')
    finally:
        # Only this invocation's UUID container; never a production container.
        try:
            cleanup = subprocess.run(['docker','rm','-f',name], capture_output=True, text=True, timeout=15)
            # --rm may already have removed a successful container.
            result['cleanup_exit'] = (0 if cleanup.returncode == 0 or
                (cleanup.returncode == 1 and 'No such container: ' + name in cleanup.stderr)
                else cleanup.returncode)
        except subprocess.TimeoutExpired:
            result['cleanup_exit'] = 124
    return result


def main():
    manifest = ROOT/'services-manifest.json'
    image = json.loads(manifest.read_text())['roles']['worker']['candidate_image']
    assert re.fullmatch(r'sha256:[0-9a-f]{64}', image)
    assert hashlib.sha256((ROOT/'test-tools.zip').read_bytes()).hexdigest() == TOOLS_SHA
    inputs = ['validate_default_runtime.py','default_entry_probe.py','test-tools.zip'] + ['tests/'+p for p in TESTS]
    receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'image': image,
        'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
        'input_sha256': {p: hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in inputs}, 'checks': {}}
    receipt['checks']['default_entry'] = isolated_check(image, "exec(open('/probe.py').read())",
        [('default_entry_probe.py','/probe.py')])
    # Append only immutable pytest tooling. No PYTHONPATH and no product-source
    # mount; installed Consumer and actual main imports must remain authoritative.
    code = ("import os,sys;assert not os.environ.get('PYTHONPATH');sys.path.append('/test-tools.zip');"
            "import main,worker,lease_renewal,app.core.outbox as o;"
            "assert o.__file__=='/usr/local/lib/python3.12/site-packages/app/core/outbox.py';"
            "assert main.__file__=='/opt/business-worker/app/main.py';"
            "assert main.create_renewal_engine is lease_renewal.create_renewal_engine;"
            "import pytest;raise SystemExit(pytest.main(" + repr(
                ['/tests/'+p for p in TESTS] + ['-q','-rsx','-p','no:cacheprovider']) + "))")
    receipt['checks']['default_pytest'] = isolated_check(image, code,
        [('tests','/tests'),('test-tools.zip','/test-tools.zip')])
    receipt['ended_utc'] = datetime.now(timezone.utc).isoformat()
    (ROOT/'default-runtime-receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt, indent=2))
    assert all(row['exit_code'] == 0 and row['cleanup_exit'] == 0 for row in receipt['checks'].values())


if __name__ == '__main__':
    main()
