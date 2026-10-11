"""Read-only post-cutover audit. Execute only after root reports a settled cutover."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import urllib.request

ROOT = Path('/opt/starchat/releases/im-worker-active-lease-20261011')
WORKER = 'starchat-business-worker-1'
API = 'starchat-business-api-1'
IMAGE = 'sha256:abda33f8fe5bb4abca45464a5d300fff8981a8b68908be1b64f6e3ee0d8a0e7f'
API_IMAGE = 'sha256:a935b4144d18ebfb7486bcc014a4441eb8cd45c06b9f97cb5b19217e0cfccab3'
API_ID = '87c62739027c607d1ae1b13af206a5960f44539a1b1a9c7ad60b3e11697c33c8'
SOURCES = {
    '/opt/business-worker/app/main.py': 'f320662c59491b66c2fe9e776c83634c16f5ac780db00d0ecc0d4fd272312494',
    '/opt/business-worker/app/worker.py': 'b59f5619156e5ea7c0c43dfc71cd729166b4aa5ee1ed6f7d02cadce1adde7a59',
    '/opt/business-worker/app/lease_renewal.py': '37ae78fa6488a81936ff81e5d753b54678edc9047d8552ee665ca8c0726bd4d1',
    '/usr/local/lib/python3.12/site-packages/app/core/outbox.py': '8306c0b0c516ab70b3e1b556a3c17ad1053a16d7f92016b4df162ea58f535a12',
    '/opt/business-api/app/core/outbox.py': '8306c0b0c516ab70b3e1b556a3c17ad1053a16d7f92016b4df162ea58f535a12',
}
GUARDS = {
    '/opt/starchat/ops/refresh-guards/business_release_guard.py': '46d98c6e2d9632b8168d20748b697744d89396852363f259d5eb0d83a7653b9b',
    '/opt/starchat/ops/refresh-guards/business_refresh_image_probe.py': '2a6de21ddc26b12bf4b0124365ba20834f821e0ea2d2700fe077f16e96b84a15',
}


def command(args, timeout=10):
    # Capture all raw output; only allowlisted summaries below may leave this process.
    completed = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if completed.returncode:
        raise RuntimeError('readonly command failed')
    return completed.stdout


def inspect(name):
    item = json.loads(command(['docker', 'inspect', name]))[0]
    state = item['State']
    return {'id': item['Id'], 'image': item['Image'], 'running': state['Running'],
            'status': state['Status'], 'health': state.get('Health', {}).get('Status'),
            'restart_count': item['RestartCount'], 'oom_killed': state['OOMKilled'],
            'started_at': state['StartedAt']}


def classify_logs(text):
    counts = Counter()
    for line in text.splitlines():
        lower = line.lower()
        # Fixed categories only; never emit the line, event ID, exception detail or payload.
        for label, pattern in {
            'traceback_lines': r'traceback \(most recent call last\)',
            'error_level_lines': r'\b(error|critical)\b',
            'warning_level_lines': r'\bwarning\b',
            'lease_lost_lines': r'outbox active claim stopped reason=lease_lost\b',
            'renewal_unknown_lines': r'outbox active claim stopped reason=renewal_unknown\b',
            'renewal_limit_lines': r'outbox active claim stopped reason=renewal_limit\b',
            'renewal_unsettled_lines': r'outbox active claim stopped reason=renewal_unsettled\b',
            'database_timeout_lines': r'(statement timeout|lock timeout|connection timeout|operationalerror)',
        }.items():
            if re.search(pattern, lower):
                counts[label] += 1
    return {'sample_lines': len(text.splitlines()), 'categories_may_overlap': True,
            'fixed_category_counts': dict(counts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-worker-id', required=True)
    parser.add_argument('--cutover-started-utc', required=True)
    args = parser.parse_args()
    if not re.fullmatch('[0-9a-f]{64}', args.expected_worker_id):
        parser.error('expected worker ID must be a full Docker ID')
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', args.cutover_started_utc):
        parser.error('cutover UTC must equal the settled deployment receipt started_utc')
    report = {'mode': 'read_only_post_cutover', 'observed_utc': datetime.now(timezone.utc).isoformat(),
              'checks': {}, 'observations': {}}

    def check(name, observe):
        try:
            value, passed = observe()
            report['observations'][name] = value
            report['checks'][name] = bool(passed)
        except Exception as error:
            # Exception text can contain command output/DSNs; emit class only.
            report['checks'][name] = False
            report['observations'][name] = {'error_type': type(error).__name__}

    def receipt():
        value = json.loads((ROOT/'deployment.json').read_text())
        observed = {key: value.get(key) for key in ('stage', 'id', 'image', 'started_utc', 'completed_utc', 'schema')}
        passed = (observed['stage'] == 'PASS' and observed['id'] == args.expected_worker_id
                  and observed['image'] == IMAGE and observed['started_utc'] == args.cutover_started_utc
                  and observed['schema'] == '0095_wallet_source_alerts')
        return observed, passed

    check('settled_receipt', receipt)
    if not report['checks']['settled_receipt']:
        report['result'] = 'NOT_VERIFIED'
        print(json.dumps(report, indent=2))
        return 1

    for role, name, expected_id, expected_image in (
            ('worker', WORKER, args.expected_worker_id, IMAGE), ('api', API, API_ID, API_IMAGE)):
        def runtime(name=name, expected_id=expected_id, expected_image=expected_image):
            value = inspect(name)
            return value, (value['id'] == expected_id and value['image'] == expected_image
                           and value['running'] and value['health'] == 'healthy'
                           and value['restart_count'] == 0 and not value['oom_killed'])
        check(role, runtime)

    def sources():
        code = ('import hashlib,json,stat;from pathlib import Path;paths=' + repr(list(SOURCES))
                + ';result={}\nfor name in paths:\n p=Path(name)\n assert stat.S_ISREG(p.lstat().st_mode)'
                + '\n result[name]=hashlib.sha256(p.read_bytes()).hexdigest()\nprint(json.dumps(result))')
        value = json.loads(command(['docker', 'exec', WORKER, 'python', '-B', '-c', code]))
        return value, value == SOURCES
    check('runtime_source_sha256', sources)
    check('permanent_guard_sha256', lambda: (
        (value := {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in GUARDS}), value == GUARDS))

    def containers():
        before = dict(line.split(' ', 1) for line in (ROOT/'private/services-before-container-ids.txt').read_text().splitlines())
        after = dict(line.split(' ', 1) for line in command(['docker', 'ps', '-a', '--no-trunc', '--format', '{{.Names}} {{.ID}}']).splitlines())
        drift = sorted(name for name in before.keys() | after.keys()
                       if name != WORKER and before.get(name) != after.get(name))
        running = command(['docker', 'ps', '--no-trunc', '--format', '{{.Names}} {{.ID}}']).splitlines()
        value = {'before_all_count': len(before), 'after_all_count': len(after), 'unrelated_drift_names': drift,
                 'running_count': len(running), 'running_id_set_sha256': hashlib.sha256('\n'.join(sorted(running)).encode()).hexdigest()}
        return value, not drift and len(before) == len(after) == 60 and len(running) == 35
    check('container_identity', containers)

    def schema():
        code = ("from app.core.config import Settings;from sqlalchemy import create_engine,text;"
                "e=create_engine(Settings().database_url,connect_args={'connect_timeout':3});\n"
                "with e.begin() as c:\n c.execute(text('SET TRANSACTION READ ONLY'))\n"
                " c.execute(text(\"SET LOCAL statement_timeout='5s'\"))\n"
                " print(c.execute(text('SELECT version_num FROM alembic_version')).scalar_one())\ne.dispose()")
        value = command(['docker', 'exec', API, 'python', '-B', '-c', code], timeout=12).strip()
        return {'expected_revision_present': value == '0095_wallet_source_alerts'}, value == '0095_wallet_source_alerts'
    check('schema', schema)

    def https_ready():
        with urllib.request.urlopen('https://liuhetong888.com/api/v1/health/ready', timeout=10) as response:
            return {'http_status': response.status}, response.status == 200
    check('api_https_readiness', https_ready)

    def logs():
        result = subprocess.run(['docker', 'logs', '--since', args.cutover_started_utc, '--tail', '2000', WORKER],
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError('bounded worker log read failed')
        value = classify_logs(result.stdout + '\n' + result.stderr)
        value.update(since_utc=args.cutover_started_utc, tail_limit=2000,
                     review_required=bool(value['fixed_category_counts']),
                     scope='bounded worker sample; zero counts do not prove complete absence of errors')
        return value, True  # Observational categories need context; not an automatic release failure/rollback.
    check('bounded_worker_log_aggregation', logs)
    structural_pass = all(report['checks'].values())
    log_review = report['observations'].get('bounded_worker_log_aggregation', {}).get('review_required', False)
    report['result'] = ('STRUCTURAL_PASS_LOG_REVIEW_REQUIRED' if log_review else 'PASS') if structural_pass else 'NOT_VERIFIED'
    print(json.dumps(report, indent=2))
    return 0 if structural_pass else 1


if __name__ == '__main__':
    raise SystemExit(main())
