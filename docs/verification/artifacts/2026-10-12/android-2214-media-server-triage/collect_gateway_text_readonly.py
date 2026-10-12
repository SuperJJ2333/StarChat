"""Supplement the unparsed gateway text format in the original fixed time window."""
from collections import Counter
from datetime import datetime, timezone
import json
import re
import subprocess

SINCE = '2026-10-12T09:16:04.133820+00:00'
UNTIL = '2026-10-12T11:16:04.133820+00:00'
ACCESS = re.compile(r'"(GET|POST|PUT|DELETE|OPTIONS|HEAD|PATCH)\s+(\S+)\s+HTTP/[^\"]+"\s+([1-5]\d\d)\b')


def route(uri):
    path = uri.split('?', 1)[0]
    for action in ('upload', 'create', 'config', 'download', 'thumbnail'):
        if re.match(r'^/_matrix/(?:media/(?:v1|v3|r0)|client/v1/media)/'+action+r'(?:/|$)', path):
            return 'matrix_media_'+action
    if path == '/_synapse/client/chatflow/recovery/v1/status':
        return 'recovery_status'
    if path.startswith('/_synapse/client/chatflow/recovery/'):
        return 'recovery_other'
    if re.match(r'^/_matrix/client/(?:v3|r0)/rooms/[^/]+/send(?:/|$)', path):
        return 'matrix_room_send'
    if path.startswith('/api/v1/media/') or path == '/api/v1/media':
        return 'business_media'
    return 'other'


def aggregate(text):
    counts, literal = Counter(), Counter()
    timestamps = []
    matched = media_unparsed = 0
    lines = text.splitlines()
    for line in lines:
        prefix = line.partition(' ')[0]
        if re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z', prefix):
            timestamps.append(prefix)
        match = ACCESS.search(line)
        if match:
            method, uri, status = match.groups()
            matched += 1
            counts[(route(uri), method, int(status))] += 1
        elif '/_matrix/media/' in line or '/_matrix/client/v1/media/' in line:
            media_unparsed += 1
        lower = line.lower()
        for label, phrase in (('too_large_body', 'client intended to send too large body'),
                              ('upstream_timeout', 'upstream timed out'), ('upstream_connect_failure', 'connect() failed')):
            if phrase in lower:
                literal[label] += 1
    return {'lines': len(lines), 'parsed_requests': matched, 'unparsed_media_literal_lines': media_unparsed,
            'tail_cap_reached': len(lines) >= 40000,
            'first_available_timestamp': min(timestamps) if timestamps else None,
            'last_available_timestamp': max(timestamps) if timestamps else None,
            'fixed_error_literal_counts': dict(literal),
            'request_counts': [{'route': r, 'method': m, 'status': s, 'count': n}
                               for (r, m, s), n in sorted(counts.items())]}


def main():
    report = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'requested_since_utc': SINCE,
              'requested_until_utc': UNTIL, 'tail_cap': 40000, 'privacy': 'Only fixed route/status counts; no URI/query/body/IDs/raw lines.'}
    try:
        result = subprocess.run(['docker', 'logs', '--timestamps', '--since', SINCE, '--until', UNTIL,
                                 '--tail', '40000', 'starchat-gateway-1'], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError('bounded gateway read failed')
        report.update(read_ok=True, result=aggregate(result.stdout+'\n'+result.stderr))
    except Exception as error:
        report.update(read_ok=False, error_type=type(error).__name__)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
