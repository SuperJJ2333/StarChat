"""Isolated Windows-host cross-build experiment; no app or cache writes."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parent
abi = sys.argv[1]
if abi not in ('arm64', 'x86_64'):
    raise SystemExit('unsupported ABI')
attempt = sys.argv[2]
if not attempt.isdecimal():
    raise SystemExit('attempt must be numeric')
recipe = root / 'build-recipe.sh'
bash = Path('C:/Program Files/Git/usr/bin/bash.exe')
command = [str(bash), str(recipe), abi]
if len(sys.argv) > 3:
    if sys.argv[3] != 'resume':
        raise SystemExit('unsupported build mode')
    command.append('resume')
started = datetime.now(timezone.utc).isoformat()
t0 = time.monotonic()
log = root / f'build-{abi}-attempt-{attempt}.log'
with log.open('wb') as output:
    result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=900)
record = {
    'started_utc': started,
    'duration_seconds': round(time.monotonic() - t0, 3),
    'command': command,
    'recipe_sha256': hashlib.sha256(recipe.read_bytes()).hexdigest(),
    'exit_code': result.returncode,
    'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest(),
}
(root / f'build-{abi}-attempt-{attempt}.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
print(json.dumps(record, indent=2))
print(log.read_text(encoding='utf-8', errors='replace')[-5000:])
raise SystemExit(result.returncode)
