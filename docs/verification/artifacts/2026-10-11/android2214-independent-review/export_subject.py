"""Export one immutable reviewed Git prefix, never the author's working bytes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('commit')
parser.add_argument('name')
args = parser.parse_args()
source = Path('C:/Users/Administrator/.codex/worktrees/android2214-release/StarChat')
base = Path(__file__).resolve().parent
target = base / args.name
if target.exists() or target.parent != base or not args.name.startswith('subject-'):
    raise ValueError('new direct subject directory required')
prefix = 'docs/verification/artifacts/2026-10-11/android2214-release/'
files = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', args.commit, '--', prefix], cwd=source).decode().splitlines()
records = []
for file in files:
    data = subprocess.check_output(['git', 'show', args.commit + ':' + file], cwd=source)
    relative = file.removeprefix(prefix)
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    records.append({'path': relative, 'git_bytes_sha256': hashlib.sha256(data).hexdigest()})
(base / (args.name + '-inputs.json')).write_text(json.dumps({'commit': args.commit, 'files': records}, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'commit': args.commit, 'exported_files': len(records), 'destination': str(target)}))
