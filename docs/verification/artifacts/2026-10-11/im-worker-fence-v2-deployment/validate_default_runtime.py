"""Capture actual argv and default-import test results without production data."""
import hashlib
import json
import subprocess
from pathlib import Path
from datetime import datetime, timezone

root = Path('/opt/starchat/releases/im-worker-fence-v2-20261011')
image = json.loads((root/'services-manifest.json').read_text())['roles']['worker']['candidate_image']
assert image == 'sha256:bfde7c86f327360738d8f8864d90a49fabd5cd2305ff938b2708554bf9838b3a'
assert hashlib.sha256((root/'test-tools.zip').read_bytes()).hexdigest() == '71a0a7c69a9027d17445d07808dd09e01919b19c61dad06e34dda3d2e6b380ee'
commands = {
    'default_entry': ['docker','run','--rm','--network','none','--read-only','--tmpfs','/tmp:rw,size=32m','-e','PYTHONDONTWRITEBYTECODE=1','-v',str(root/'default_entry_probe.py')+':/probe.py:ro','--entrypoint','python',image,'-c',"exec(open('/probe.py').read())"],
    'default_pytest': ['docker','run','--rm','--network','none','--read-only','--tmpfs','/tmp:rw,size=64m','-v',str(root/'tests')+':/tests:ro','-v',str(root/'test-tools.zip')+':/test-tools.zip:ro','-e','PYTHONDONTWRITEBYTECODE=1','-e','PYTEST_DISABLE_PLUGIN_AUTOLOAD=1','--entrypoint','python',image,'-c',"import sys;sys.path.append('/test-tools.zip');import app.core.outbox as o;assert o.__file__=='/usr/local/lib/python3.12/site-packages/app/core/outbox.py';import pytest;raise SystemExit(pytest.main(['/tests/test_worker_claim_fencing.py','/tests/test_worker_lease_window.py','-q','-rsx','-p','no:cacheprovider']))"],
}
receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'image': image,
           'probe_sha256': hashlib.sha256((root/'default_entry_probe.py').read_bytes()).hexdigest(),
           'test_tools_sha256': hashlib.sha256((root/'test-tools.zip').read_bytes()).hexdigest(),
           'checks': {}}
for name, argv in commands.items():
    result = subprocess.run(argv, capture_output=True, text=True, timeout=90)
    receipt['checks'][name] = {'argv': argv, 'exit_code': result.returncode,
                              'stdout': result.stdout, 'stderr': result.stderr}
receipt['ended_utc'] = datetime.now(timezone.utc).isoformat()
(root/'default-runtime-receipt.json').write_text(json.dumps(receipt, indent=2))
print(json.dumps(receipt, indent=2))
assert all(row['exit_code'] == 0 for row in receipt['checks'].values())
