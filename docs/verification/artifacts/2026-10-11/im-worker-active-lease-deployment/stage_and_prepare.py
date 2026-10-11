"""Verify uploaded fixed bundle, stage a copy of immutable tools, build only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

os.umask(0o077)
ROOT = Path('/opt/starchat/releases/im-worker-active-lease-20261011')
EXPECTED = 'a99c26e1f72d95276d53eeae31306784e954af22827769825b97c3d76f1b8b45'
assert hashlib.sha256((ROOT/'payload.zip').read_bytes()).hexdigest() == EXPECTED
allowed = {'prepare.py','deploy.py','validate_default_runtime.py','default_entry_probe.py','payload-spec.json',
    'worker/main.py','worker/worker.py','worker/lease_renewal.py','worker/outbox.py','worker/outbox-source.py',
    'tests/test_worker_active_lease.py','tests/test_published_worker_entrypoint.py',
    'tests/test_worker_claim_fencing.py','tests/test_worker_lease_window.py'}
with zipfile.ZipFile(ROOT/'payload.zip') as archive:
    assert len(archive.namelist()) == len(allowed) and set(archive.namelist()) == allowed
    archive.extractall(ROOT)
tools = Path('/opt/starchat/releases/im-worker-fence-v2-20261011/test-tools.zip')
assert hashlib.sha256(tools.read_bytes()).hexdigest() == '71a0a7c69a9027d17445d07808dd09e01919b19c61dad06e34dda3d2e6b380ee'
shutil.copyfile(tools, ROOT/'test-tools.zip')
print(json.dumps({'bundle_verified': EXPECTED, 'tools_reused': True}), flush=True)
subprocess.run([sys.executable, str(ROOT/'prepare.py')], check=True, timeout=420)
