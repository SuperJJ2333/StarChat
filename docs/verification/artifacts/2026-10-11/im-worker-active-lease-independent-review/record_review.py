"""Hash reviewed frozen source and independent evidence; no source writes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
SOURCE = Path('C:/Users/Administrator/.codex/worktrees/im-worker-active-lease/StarChat')
COMMIT = 'c3dd314212c73414c5ab371b4363e077bc9104c2'
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=SOURCE, text=True).strip() == COMMIT
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=SOURCE)
paths = ['services/business-worker/app/worker.py', 'services/business-worker/app/main.py',
         'services/business-worker/app/lease_renewal.py', 'services/business-api/app/core/outbox.py',
         'tests/business_worker/test_worker_active_lease.py',
         'tests/business_worker/test_published_worker_entrypoint.py',
         'tests/business_worker/test_worker_lease_window.py',
         'tests/business_worker/test_worker_active_lease_postgres.py',
         'docs/superpowers/plans/2026-10-11-im-worker-active-lease.md']
source = []
for path in paths:
    blob = subprocess.check_output(['git', 'show', COMMIT + ':' + path], cwd=SOURCE)
    raw = (SOURCE / path).read_bytes()
    assert raw.replace(b'\r\n', b'\n') == blob
    source.append({'path': path, 'git_blob_sha256': hashlib.sha256(blob).hexdigest(),
                   'git_blob_bytes': len(blob), 'working_bytes_sha256': hashlib.sha256(raw).hexdigest()})
evidence = {}
for path in sorted(ROOT.iterdir()):
    if path.is_file() and path.name != 'review-identities.json':
        evidence[path.name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}
result = {'reviewed_commit': COMMIT, 'recorded_utc': datetime.now(timezone.utc).isoformat(),
          'review_order': ['SPEC/domain', 'Quality/Security'], 'distinct_cases_executed': 35,
          'candidate_image_checked': False, 'production_operations': False,
          'commands': [
              'py -3.12 -m pytest -q -p no:cacheprovider tests/business_worker/test_worker_active_lease.py tests/business_worker/test_published_worker_entrypoint.py tests/business_worker/test_worker_lease_window.py --basetemp <review>/pytest-focused',
              'py -3.12 -m pytest -q -p no:cacheprovider tests/business_worker/test_worker_active_lease_postgres.py tests/business_worker/test_worker_lease_window.py --basetemp <review>/pytest-pg',
              'py -3.12 -m pytest -q -p no:cacheprovider <review>/test_independent_lease_edges.py --basetemp <review>/pytest-independent',
          ],
          'environment': {'shell': 'pwsh.exe; console/pipeline UTF-8 without BOM',
              'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8', 'PYTHONDONTWRITEBYTECODE': '1',
              'PYTHONPATH': '<frozen-source>/services/business-api;<frozen-source>/services/business-worker/app;<frozen-source>',
              'IM_WORKER_LEASE_TEST_DATABASE_URL': 'postgresql+psycopg://lease_fixture@127.0.0.1:55483/im_worker_lease_independent_utf8 (last two calls only)'},
          'source': source, 'evidence': evidence}
(ROOT / 'review-identities.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8', newline='\n')
print('Frozen source unchanged;', len(evidence), 'independent evidence identities recorded')
