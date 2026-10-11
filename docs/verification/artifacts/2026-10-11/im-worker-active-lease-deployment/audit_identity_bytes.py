"""Check the committed evidence identity domain without Docker or server access."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
PREFIX = HERE.relative_to(REPO).as_posix()
reference = sys.argv[1] if len(sys.argv) > 1 else ''


def git_bytes(name):
    return subprocess.check_output(
        ['git', 'show', reference + ':' + PREFIX + '/' + name], cwd=REPO)


identities = json.loads(git_bytes('deployment-input-identities.json'))
mismatches = []
for name, expected in identities['files'].items():
    observed = hashlib.sha256(git_bytes(name)).hexdigest()
    if observed != expected:
        mismatches.append({'name': name, 'recorded': expected, 'git_blob': observed})
print(json.dumps({'result': 'FAIL' if mismatches else 'PASS',
                  'checked_byte_source': 'Git blobs (not checkout bytes)',
                  'mismatches': mismatches}, indent=2))
raise SystemExit(1 if mismatches else 0)
