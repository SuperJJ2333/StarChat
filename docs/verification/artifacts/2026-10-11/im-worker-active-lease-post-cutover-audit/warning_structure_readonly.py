"""One authorized log-structure read; no message, parameters or exception output."""
from collections import Counter
from datetime import datetime, timezone
import json
import re
import subprocess

WORKER_ID = 'db5d65ff01ae55a878fe1a2231e25954df84f9aec8bfdabfacd90c535dae0b7c'
SINCE = '2026-10-11T10:39:52Z'
LOGGER = r'[A-Za-z][A-Za-z0-9_.-]{0,80}'
TIMESTAMP = r'\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?'


def logger_name(line):
    try:
        value = json.loads(line)
    except (ValueError, TypeError):
        value = None
    if isinstance(value, dict):
        name = value.get('logger')
        if value.get('level') in ('WARNING', 'WARN', 'warning', 'warn') and isinstance(name, str) and re.fullmatch(LOGGER, name):
            return name
        return None
    patterns = (
        r'^WARNING:(' + LOGGER + r'):',
        r'^' + TIMESTAMP + r'\s+WARNING:(' + LOGGER + r'):',
        r'^' + TIMESTAMP + r'\s+WARNING\s+\[(' + LOGGER + r')\](?:\s|:)',
        r'^' + TIMESTAMP + r'\s+-\s+(' + LOGGER + r')\s+-\s+WARNING\s+-',
    )
    for pattern in patterns:
        match = re.match(pattern, line)
        if match:
            return match.group(1)
    return None


def summarize(lines):
    names = Counter()
    unknown = 0
    flags = dict.fromkeys(('sqlalchemy_literal', 'deprecation_literal', 'optional_provider_literal', 'connection_literal'), False)
    warning_lines = [line for line in lines if re.search(r'\b(?:warning|warn)\b', line, re.IGNORECASE)]
    for line in warning_lines:
        name = logger_name(line)
        if name is None:
            unknown += 1
        else:
            names[name] += 1
        lower = line.lower()
        flags['sqlalchemy_literal'] |= 'sqlalchemy' in lower
        flags['deprecation_literal'] |= 'deprecation' in lower or 'deprecated' in lower
        flags['optional_provider_literal'] |= 'optional-provider' in lower or 'optional provider' in lower
        flags['connection_literal'] |= 'connection' in lower
    return {'warning_lines': len(warning_lines), 'logger_counts': dict(sorted(names.items())),
            'unknown_logger_lines': unknown, 'fixed_literal_flags': flags}


def main():
    report = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'since_utc': SINCE,
              'tail_limit': 2000, 'timeout_seconds': 12, 'prior_receipts_preserved': True}
    try:
        result = subprocess.run(['docker', 'logs', '--since', SINCE, '--tail', '2000', WORKER_ID],
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError('bounded read failed')
        report.update(summarize(result.stdout.splitlines() + result.stderr.splitlines()))
        report['result'] = 'LOGGER_STRUCTURE_OBSERVED_CAUSE_UNRESOLVED'
        report['interpretation'] = 'Logger names and literal booleans are locating hints only; no cause, severity or configuration acceptance inferred.'
        print(json.dumps(report, indent=2))
        return 0
    except Exception as error:
        report.update(result='NOT_VERIFIED', error_type=type(error).__name__)
        print(json.dumps(report, indent=2))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
