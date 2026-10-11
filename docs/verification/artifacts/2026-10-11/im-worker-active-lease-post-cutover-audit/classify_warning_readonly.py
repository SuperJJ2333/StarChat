"""One separately authorized bounded log classification; no raw log output."""
from datetime import datetime, timezone
import json
import re
import subprocess

WORKER_ID = 'db5d65ff01ae55a878fe1a2231e25954df84f9aec8bfdabfacd90c535dae0b7c'
SINCE = '2026-10-11T10:39:52Z'


def classify(lines):
    warning = dict.fromkeys(('custody_not_configured_maintenance_skipped',
                            'maintenance_task_failed', 'outbox_reap_failed', 'other_warning'), 0)
    other = dict.fromkeys(('traceback_lines', 'error_level_lines', 'lease_lost',
                          'renewal_unknown', 'renewal_limit', 'renewal_unsettled'), 0)
    for line in lines:
        lower = line.lower()
        if re.search(r'\bwarning\b', lower):
            if re.search(r'wallet custody not configured \(mode=[^\r\n)]*\); wallet maintenance skipped\b', lower):
                category = 'custody_not_configured_maintenance_skipped'
            elif 'maintenance task failed name=' in lower and ' consecutive=' in lower and ' error=' in lower:
                category = 'maintenance_task_failed'
            elif 'outbox reap failed error=' in lower:
                category = 'outbox_reap_failed'
            else:
                category = 'other_warning'
            warning[category] += 1
        other['traceback_lines'] += int('traceback (most recent call last)' in lower)
        other['error_level_lines'] += int(bool(re.search(r'\b(error|critical)\b', lower)))
        for reason in ('lease_lost', 'renewal_unknown', 'renewal_limit', 'renewal_unsettled'):
            other[reason] += int(bool(re.search(r'outbox active claim stopped reason=' + reason + r'\b', lower)))
    return {'warning_categories': warning, 'other_fixed_counts': other,
            'unknown_warning_requires_review': warning['other_warning'] > 0}


def main():
    report = {'observed_utc': datetime.now(timezone.utc).isoformat(), 'since_utc': SINCE,
              'tail_limit': 2000, 'timeout_seconds': 12, 'original_audit_preserved': True}
    try:
        result = subprocess.run(['docker', 'logs', '--since', SINCE, '--tail', '2000', WORKER_ID],
                                capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError('bounded read failed')
        lines = [line for line in result.stdout.splitlines() + result.stderr.splitlines() if line.strip()]
        report.update(classify(lines), nonempty_combined_stream_lines=len(lines))
        report['result'] = 'UNKNOWN_WARNING_REQUIRES_REVIEW' if report['unknown_warning_requires_review'] else 'BOUNDED_WARNING_CLASSIFIED'
        report['scope'] = 'Fixed categories only; no mode, exception, event ID or raw line output. Classification is not a configuration or financial-function acceptance.'
        print(json.dumps(report, indent=2))
        return 0
    except Exception as error:
        report.update(result='NOT_VERIFIED', error_type=type(error).__name__)
        print(json.dumps(report, indent=2))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
