"""Final fixed-literal classification; never print a URI or query value."""
from collections import Counter
from datetime import datetime, timezone
import json
import re
import subprocess

SINCE = '2026-10-12T09:16:04.133820+00:00'
UNTIL = '2026-10-12T11:16:04.133820+00:00'
ACCESS = re.compile(r'"(GET|POST|PUT|DELETE|OPTIONS|HEAD|PATCH)\s+(\S+)\s+HTTP/[^\"]+"\s+([1-5]\d\d)\b')


def main():
    report = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'requested_since_utc': SINCE,
              'requested_until_utc': UNTIL, 'tail_cap': 40000}
    try:
        result = subprocess.run(['docker', 'logs', '--timestamps', '--since', SINCE, '--until', UNTIL,
                                 '--tail', '40000', 'starchat-gateway-1'], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise RuntimeError('bounded read failed')
        counts = Counter()
        for line in result.stdout.splitlines()+result.stderr.splitlines():
            match = ACCESS.search(line)
            if not match:
                continue
            method, uri, status = match.groups()
            path, _, query = uri.partition('?')
            if status == '503':
                category = 'matrix_push_notify' if path == '/_matrix/push/v1/notify' else 'other_503'
                counts[(category, method, int(status))] += 1
            if path == '/api/v1/auth/refresh':
                category = 'refresh_known_probe' if re.search(r'(?:^|&)starchat_probe=1(?:&|$)', query) else 'refresh_other_or_unmarked'
                counts[(category, method, int(status))] += 1
        report.update(read_ok=True, fixed_class_counts=[{'category': c, 'method': m, 'status': s, 'count': n}
                                                      for (c, m, s), n in sorted(counts.items())])
    except Exception as error:
        report.update(read_ok=False, error_type=type(error).__name__)
    report['privacy'] = 'Only exact public endpoint categories and known probe boolean; no URI/query values/body/identity printed.'
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
