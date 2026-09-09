"""Run on the Linux deployment host before replacing wallet containers.

Only schema-v1 structured diagnostics are archived; never raw Docker output.
Retention deletion is explicit (--prune) and restricted to our flat archive files.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path('/opt/starchat/diagnostic-archives')
CONTAINERS = ('starchat-business-api-1', 'starchat-business-worker-1', 'starchat-tron-watch-tron-watch-1')
FIELDS = frozenset(('timestamp', 'schema_version', 'service', 'component', 'event', 'level',
    'reason_code', 'trace_id', 'request_id', 'incident_id', 'event_id', 'duration_ms',
    'http_status', 'stage', 'route', 'failed_conditions', 'exception_type', 'frames', 'run_id', 'observation_id',
    'checkpoint_ms', 'solid_block', 'solid_timestamp_ms', 'heartbeat_age_ms',
    'observation_age_ms', 'solid_head_age_ms', 'freshness_limit_ms', 'fresh_until_ms',
    'pending_age_ms', 'generation', 'events_added', 'page_count', 'transaction_count',
    'budget_ms', 'suppressed_count', 'status', 'reconciliation', 'action'))


def diagnostic_line(line):
    if len(line) > 16384:
        return None
    try:
        data = json.loads(line)
    except (ValueError, TypeError):
        return None
    if (not isinstance(data, dict) or data.get('schema_version') != 1
            or data.get('service') not in ('business-api', 'business-worker', 'tron-watch')
            or data.get('level') not in ('ERROR', 'WARNING', 'INFO', 'DEBUG')
            or not isinstance(data.get('event'), str)):
        return None
    return {key: value for key, value in data.items() if key in FIELDS}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--prune', action='store_true', help='delete own archives older than 14 days')
    args = parser.parse_args()
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    if ROOT.is_symlink() or ROOT.resolve() != ROOT:
        raise RuntimeError('ARCHIVE_PATH_INVALID')
    ROOT.chmod(0o700)
    if args.prune:
        removed = 0
        for path in ROOT.iterdir():
            if (not path.is_symlink() and path.is_file()
                    and re.fullmatch(r'\d{8}T\d{12}Z-starchat-[a-z0-9-]+\.jsonl', path.name)
                    and path.stat().st_mtime < time.time()-14*86400):
                path.unlink()
                removed += 1
        print(json.dumps({'removed_archives': removed}))
        return
    batch = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    for container in CONTAINERS:
        path = ROOT/f'{batch}-{container}.jsonl'
        count = 0
        with path.open('x', encoding='utf-8') as output:
            process = subprocess.Popen(['docker', 'logs', '--since', '336h', container],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
            for line in process.stdout:
                record = diagnostic_line(line)
                if record is not None:
                    output.write(json.dumps(record, separators=(',', ':'))+'\n')
                    count += 1
            if process.wait() != 0:
                raise RuntimeError('DIAGNOSTIC_ARCHIVE_FAILED')
        path.chmod(0o600)
        print(json.dumps({'container': container, 'records': count, 'archive': str(path)}))


if __name__ == '__main__':
    main()
