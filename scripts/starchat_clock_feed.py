"""Feed agreed fresh HTTPS UTC into an explicitly configured manual chrony.

Run only on the managed server. This command never steps the clock. The pinned
chronyd configuration must exclude makestep/initstepslew and automatic sources.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import os


def acceptable(samples):
    if len(samples) != 2 or any(not 0 <= rtt <= 2 or abs(offset) > 120 for offset, rtt in samples):
        return False
    return max(s[0] for s in samples) - min(s[0] for s in samples) <= 2


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    if not str(directory).startswith('/opt/starchat/releases/clock-'):
        raise SystemExit('managed release directory required')
    spec = importlib.util.spec_from_file_location('clock_reference', directory / 'clock_health.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    start_mono, start_wall = time.monotonic(), time.time()
    with ThreadPoolExecutor(max_workers=2) as pool:
        samples = list(pool.map(module.probe_utc, module.SOURCES))
    if not acceptable(samples) or abs(time.time() - start_wall - (time.monotonic() - start_mono)) > .5:
        raise SystemExit('independent clock references rejected; no correction applied')
    offset = sum(s[0] for s in samples) / len(samples)
    healthy = all(abs(s[0]) + .5 + s[1] / 2 <= 5 for s in samples)
    print(json.dumps(dict(offset_seconds=round(offset, 3), healthy=healthy,
        reference_rtt_seconds=[round(s[1], 3) for s in samples], apply_requested=args.apply)))
    if args.apply:
        allowed = {'manual', 'maxdrift 500', 'maxslewrate 100000', 'port 0', 'cmdport 0',
            'bindcmdaddress /run/starchat-clock/chronyd.sock',
            'pidfile /run/starchat-clock/chronyd.pid', 'driftfile /var/lib/starchat-clock/drift'}
        if set((directory / 'chrony.conf').read_text().splitlines()) != allowed:
            raise SystemExit('unexpected effective clock configuration; no correction applied')
        state_file = Path('/var/lib/starchat-clock/feed.json')
        boot_id = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        if state_file.exists():
            state = json.loads(state_file.read_text())
            if state['boot_id'] == boot_id and time.monotonic() - state['monotonic'] < 300:
                print('fresh sample observed; correction skipped to preserve minimum feed spacing')
                return
        # Supported manual source input; chronyd disciplines gradually. No date -s,
        # clock_settime, makestep, -q, or restoring the old incorrect wall time.
        reference = datetime.fromtimestamp(time.time() - offset, timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
        subprocess.run([str(directory / 'usr/bin/chronyc'), '-h', '/run/starchat-clock/chronyd.sock',
            'settime', reference], check=True, timeout=10, env={'PATH': '/usr/bin:/bin', 'TZ': 'UTC'})
        temporary = state_file.with_suffix('.new')
        temporary.write_text(json.dumps(dict(boot_id=boot_id, monotonic=time.monotonic())))
        temporary.chmod(0o600)
        os.replace(temporary, state_file)


if __name__ == '__main__':
    main()
