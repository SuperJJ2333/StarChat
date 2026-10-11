"""Isolated candidate checks only; never invoke deploy/rollback or alter a service."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path('/opt/starchat/releases/im-worker-active-lease-20261011')
GUARD = Path('/opt/starchat/ops/refresh-guards/business_release_guard.py')
PROBE = GUARD.with_name('business_refresh_image_probe.py')
assert hashlib.sha256(GUARD.read_bytes()).hexdigest() == '46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b'
assert hashlib.sha256(PROBE.read_bytes()).hexdigest() == '2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15'
roles = json.loads((ROOT/'services-manifest.json').read_text())['roles']
before = dict(line.split(' ',1) for line in (ROOT/'private/services-before-container-ids.txt').read_text().splitlines())
receipt = {'started_utc': datetime.now(timezone.utc).isoformat(), 'stage': 'isolated_checks_only', 'checks': {}}
try:
    default = subprocess.run([sys.executable,str(ROOT/'validate_default_runtime.py')], capture_output=True, text=True, timeout=225)
    (ROOT/'default-runtime-output.txt').write_text(default.stdout + default.stderr)
    receipt['checks']['default_runtime_exit'] = default.returncode
    assert default.returncode == 0, 'default runtime checks failed'
    argv = [sys.executable,str(GUARD),'check',
        '--api-image',roles['api']['candidate_image'],'--api-image',roles['api']['old_image'],
        '--worker-image',roles['worker']['candidate_image'],'--worker-image',roles['worker']['old_image']]
    protocol = subprocess.run(argv, capture_output=True, text=True, timeout=450)
    (ROOT/'protocol-check-output.txt').write_text(protocol.stdout + protocol.stderr)
    receipt['checks']['protocol_exit'] = protocol.returncode
    assert protocol.returncode == 0, 'role protocol checks failed'
finally:
    after = dict(line.split(' ',1) for line in subprocess.check_output(
        ['docker','ps','-a','--no-trunc','--format','{{.Names}} {{.ID}}'],text=True,timeout=10).splitlines())
    receipt.update(ended_utc=datetime.now(timezone.utc).isoformat(), before_count=len(before), after_count=len(after),
        exact_container_ids_unchanged=(before==after),
        added=sorted(set(after)-set(before)), removed=sorted(set(before)-set(after)),
        changed=sorted(name for name in before.keys() & after.keys() if before[name]!=after[name]))
    (ROOT/'candidate-checks-receipt.json').write_text(json.dumps(receipt,indent=2))
    print(json.dumps(receipt,indent=2),flush=True)
    assert before == after, 'temporary containers/runtime drift must be reconciled before publication'
