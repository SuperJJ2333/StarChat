"""Classify remaining gateway errors with static route vocabulary only."""
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
import re
import subprocess

SINCE = '2026-10-12T09:16:04.133820+00:00'
UNTIL = '2026-10-12T11:16:04.133820+00:00'
ACCESS = re.compile(r'"(GET|POST|PUT|DELETE|OPTIONS|HEAD|PATCH)\s+(\S+)\s+HTTP/[^\"]+"\s+([1-5]\d\d)\b')
SAFE = set('_matrix _synapse client media r0 v1 v3 api auth login refresh matrix matrix-recovery-authorize config upload create download thumbnail chatflow recovery status ready health rooms send devices sync support moments friends users me settings sessions requests'.split())


def aggregate(lines):
    errors, media_nonaccess = Counter(), Counter()
    upload_times = defaultdict(list)
    for line in lines:
        match = ACCESS.search(line)
        if match:
            method, uri, status = match.groups()
            path = uri.split('?', 1)[0]
            if int(status) >= 400:
                shape = '/'+'/'.join(part if part in SAFE else '[segment]' for part in path.strip('/').split('/'))
                errors[(shape, method, int(status))] += 1
            if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/upload(?:/|$)', path):
                prefix = line.partition(' ')[0]
                if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', prefix):
                    upload_times[int(status)].append(prefix)
        elif '/_matrix/media/' in line or '/_matrix/client/v1/media/' in line:
            if 'a client request body is buffered to a temporary file' in line.lower():
                media_nonaccess['request_body_buffered_to_temporary_file'] += 1
            else:
                media_nonaccess['unclassified_media_nonaccess_line'] += 1
    return {'static_error_route_shapes': [{'shape': p, 'method': m, 'status': s, 'count': n}
                                         for (p, m, s), n in sorted(errors.items())],
            'media_nonaccess_fixed_classes': dict(media_nonaccess),
            'upload_time_ranges_by_status': [{'status': status, 'count': len(times), 'first_utc': min(times), 'last_utc': max(times)}
                                             for status, times in sorted(upload_times.items())]}


def main():
    report = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'requested_since_utc': SINCE,
              'requested_until_utc': UNTIL, 'tail_cap': 40000}
    try:
        result = subprocess.run(['docker', 'logs', '--timestamps', '--since', SINCE, '--until', UNTIL,
                                 '--tail', '40000', 'starchat-gateway-1'], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError('bounded log read failed')
        report.update(read_ok=True, result=aggregate(result.stdout.splitlines()+result.stderr.splitlines()))
    except Exception as error:
        report.update(read_ok=False, error_type=type(error).__name__)
    report['privacy'] = 'Dynamic path segments replaced, queries discarded; no IP/user/body/token/raw line output.'
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
