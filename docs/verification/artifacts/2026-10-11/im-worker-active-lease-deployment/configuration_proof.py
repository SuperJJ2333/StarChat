"""Read private configuration only to emit non-sensitive equality proofs."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
from datetime import datetime, timezone

ROOT = Path('/opt/starchat/releases/im-worker-active-lease-20261011')
manifest = json.loads((ROOT/'services-manifest.json').read_text())
proof = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'roles': {}}
for role, row in manifest['roles'].items():
    old = json.loads((ROOT/'private'/f'{role}-rollback.json').read_text())
    new = json.loads((ROOT/'private'/f'{role}-candidate.json').read_text())
    assert set(old['services']) == set(new['services']) == {row['service']}
    assert old['services'][row['service']]['image'] == row['old_image']
    assert new['services'][row['service']]['image'] == row['candidate_image']
    compare = copy.deepcopy(new)
    compare['services'][row['service']]['image'] = old['services'][row['service']]['image']
    assert compare == old
    if role == 'api':
        assert new == old
    live = json.loads(subprocess.check_output(['docker','inspect',row['name']],text=True,timeout=10))[0]
    assert live['Id'] == row['id'] and live['Image'] == row['old_image']
    proof['roles'][role] = {'service': row['service'], 'only_image_may_differ': True,
        'fully_identical': old == new, 'live_id_unchanged': True, 'live_image_unchanged': True,
        'running': live['State']['Running'], 'health': live['State'].get('Health',{}).get('Status')}
for name, expected in {
    'business_release_guard.py':'46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b',
    'business_refresh_image_probe.py':'2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15',
}.items():
    digest = hashlib.sha256((Path('/opt/starchat/ops/refresh-guards')/name).read_bytes()).hexdigest()
    assert digest == expected
    proof[name] = digest
print(json.dumps(proof,indent=2))
