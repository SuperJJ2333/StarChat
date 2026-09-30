"""Summarize closed startup metadata from stdin or explicitly supplied local logs.

This stdlib-only tool does not connect to a server, read sessions, or send alerts.
"""
import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'docs/verification/artifacts'
MAX_LINE_BYTES = 65536
MAX_SCAN_BYTES = 16 * 1024 * 1024
MAX_LINES = 100000
MAX_EVENTS = 10000
MAX_SAMPLES = 100
UUID4_PATTERN = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
PATTERNS = {
    'event_id': UUID4_PATTERN,
    'occurred_at': r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00(Z|\+00:00)$',
    'app_version': r'^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$',
    'os_version': r'^([0-9]{1,3}(\.[0-9]{1,3}){0,2}|unknown)$',
}
# Copied closed enums are checked against the API's AST by the parity test.
# Importing the API here would unnecessarily require FastAPI, Pydantic and Redis.
ENUMS = {
    'platform': {'ios'},
    'stage': {'initialization', 'installation_check', 'diagnostic_salt',
              'installation_identity', 'matrix_preflight', 'start_application',
              'session_bootstrap', 'local_restore'},
    'boundary': {'version_load', 'preferences_load', 'marker_read', 'protected_data_probe',
                 'container_probe', 'marker_register', 'installation_cleanup', 'reconcile',
                 'diagnostic_salt', 'installation_identity', 'identity_snapshot',
                 'database_presence', 'database_header', 'database_identity_read',
                 'olm_identity_check', 'original_identity_search', 'database_key',
                 'database_open', 'client_migration', 'application_start', 'local_identity',
                 'matrix_grant', 'switch_local_clear', 'matrix_login', 'matrix_sync',
                 'identity_binding', 'account_storage', 'matrix_session', 'local_restore', 'bootstrap'},
    'category': {'protected_data', 'keychain_permission', 'platform', 'metadata', 'database',
                 'filesystem', 'matrix_identity', 'matrix_credentials', 'matrix_rejected',
                 'matrix_rate_limited', 'matrix_service', 'network', 'unknown'},
    'preflight_cause': {'missingDatabaseWithBinding', 'missingDatabaseWithKey', 'missingKey',
                        'missingOlmAccount', 'fingerprintMismatch', 'identityMismatch', 'unreadable',
                        'originalIdentityElsewhere', 'multipleCandidates', 'recoveryPending',
                        'legacyPlaintextMigrationDeferred'},
    'native_status': {-25308, -34018, -25291, -25300, -50, 'other'},
    'login_stage': {'L01', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07', 'L08'},
}
OPTIONAL_FIELDS = {'preflight_cause', 'native_status', 'login_stage'}
REPORT_FIELDS = {'schema', 'platform', 'event_id', 'occurred_at', 'app_version', 'build',
                 'os_version', 'stage', 'boundary', 'category', 'count'} | OPTIONAL_FIELDS
GROUP_FIELDS = ('app_version', 'build', 'stage', 'boundary', 'category',
                'native_status', 'preflight_cause', 'login_stage')
COVERAGE = [
    'Counts describe validated retained metadata log emissions, not verified device failures or a crash rate',
    'Anonymous client declarations are untrusted; no account, installation, device, source or IP identity is exported',
    'Emission can precede receipt confirmation; UUID deduplication does not provide exactly-once delivery',
    'Scan, event and sample limits are bounded; retained-log coverage is unverified',
    'No emissions can mean unavailable logs, endpoint 404, an undistributed client, offline or dropped reports',
    'Historical UTC minute reports are validated without reapplying the live API 24h admission window',
]


def _uint(value, low, high):
    return type(value) is int and low <= value <= high


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Invalid JSON')
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError('Invalid JSON')


def _decode(value):
    return json.loads(value, object_pairs_hook=_unique_object, parse_constant=_invalid_constant)


def _candidate(line):
    """Accept bare markers, Docker timestamp/prefixes and bounded log/message wrappers."""
    if isinstance(line, bytes):
        line = line.decode('utf-8')
    start = line.find('{')
    row = _decode(line[start:] if start >= 0 else line)
    for _ in range(4):
        if not isinstance(row, dict):
            return None
        if row.get('type') == 'startup_diagnostics':
            return row
        wrapper = [key for key in ('message', 'log') if key in row]
        if len(wrapper) != 1:
            return None
        row = row[wrapper[0]]
        if isinstance(row, str):
            row = _decode(row)
    raise ValueError('Envelope nesting limit')


def validate_report(row):
    """Reject extras; return a fresh closed report with normalized optional fields."""
    fields = set(row) - {'type'}
    if (row.get('type') != 'startup_diagnostics'
            or not REPORT_FIELDS - OPTIONAL_FIELDS <= fields <= REPORT_FIELDS):
        raise ValueError('Invalid report')
    if not _uint(row['schema'], 1, 1) or not _uint(row['build'], 1, 10000000):
        raise ValueError('Invalid report')
    if not _uint(row['count'], 1, 100):
        raise ValueError('Invalid report')
    for field, pattern in PATTERNS.items():
        if not isinstance(row[field], str) or re.fullmatch(pattern, row[field]) is None:
            raise ValueError('Invalid report')
    for field, allowed in ENUMS.items():
        value = row.get(field)
        if value is None and field in OPTIONAL_FIELDS:
            continue
        expected_types = (str, int) if field == 'native_status' else (str,)
        if type(value) not in expected_types or value not in allowed:
            raise ValueError('Invalid report')
    if row.get('native_status') is not None and row['category'] not in (
            'platform', 'protected_data', 'keychain_permission'):
        raise ValueError('Invalid report')
    occurred = datetime.fromisoformat(row['occurred_at'].replace('Z', '+00:00'))
    safe = {field: row.get(field) for field in sorted(REPORT_FIELDS)}
    safe['occurred_at'] = occurred.isoformat().replace('+00:00', 'Z')
    return safe


def _validate_limits(max_lines, max_events, max_samples, max_scan_bytes):
    for value, low, high in ((max_lines, 1, MAX_LINES), (max_events, 1, MAX_EVENTS),
                             (max_samples, 0, MAX_SAMPLES), (max_scan_bytes, 1, MAX_SCAN_BYTES)):
        if not _uint(value, low, high):
            raise ValueError('Invalid collection bounds')


def collect_logs(lines, *, max_lines=20000, max_events=MAX_EVENTS,
                 max_samples=20, max_scan_bytes=MAX_SCAN_BYTES):
    """Bounded pure filtering; no original lines or envelope fields are returned."""
    _validate_limits(max_lines, max_events, max_samples, max_scan_bytes)
    counts = dict.fromkeys(('scanned_lines', 'scanned_bytes', 'unique_events', 'occurrence_count',
                            'duplicate_lines', 'conflicting_duplicate_lines', 'rejected_lines',
                            'ignored_lines', 'oversized_lines', 'dropped_event_lines'), 0)
    events, groups, samples = {}, {}, []
    iterator = iter(lines)
    for _ in range(max_lines):
        if counts['scanned_bytes'] >= max_scan_bytes:
            break
        try:
            line = next(iterator)
        except StopIteration:
            break
        counts['scanned_lines'] += 1
        try:
            if not isinstance(line, (str, bytes)):
                raise ValueError('Invalid line')
            size = len(line if isinstance(line, bytes) else line.encode('utf-8'))
            remaining = max_scan_bytes - counts['scanned_bytes']
            counts['scanned_bytes'] += min(size, remaining)
            if size > MAX_LINE_BYTES:
                counts['oversized_lines'] += 1
                continue
            if size > remaining:
                counts['rejected_lines'] += 1
                continue
            row = _candidate(line)
            if row is None:
                counts['ignored_lines'] += 1
                continue
            safe = validate_report(row)
            event_id = safe['event_id']
            if event_id in events:
                field = ('duplicate_lines' if events[event_id] == safe
                         else 'conflicting_duplicate_lines')
                counts[field] += 1
                continue
            if len(events) >= max_events:
                counts['dropped_event_lines'] += 1
                continue
            events[event_id] = safe
            counts['unique_events'] += 1
            counts['occurrence_count'] += safe['count']
            group_key = tuple(safe[field] for field in GROUP_FIELDS)
            group = groups.setdefault(group_key, {field: safe[field] for field in GROUP_FIELDS}
                                      | {'unique_events': 0, 'occurrence_count': 0})
            group['unique_events'] += 1
            group['occurrence_count'] += safe['count']
            if len(samples) < max_samples:
                samples.append(safe)
        except (ValueError, TypeError, KeyError, UnicodeError, OverflowError, RecursionError):
            counts['rejected_lines'] += 1
    collected = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    truncated = (counts['scanned_lines'] >= max_lines or counts['scanned_bytes'] >= max_scan_bytes
                 or counts['dropped_event_lines'] > 0)
    return {'groups': sorted(groups.values(), key=lambda row: json.dumps(row, sort_keys=True)),
            'samples': samples, 'metadata': {
                'schema_version': 1, 'collected_at': collected.isoformat().replace('+00:00', 'Z'),
                'max_lines': max_lines, 'max_line_bytes': MAX_LINE_BYTES,
                'max_scan_bytes': max_scan_bytes, 'max_events': max_events, 'max_samples': max_samples,
                **counts, 'samples_omitted': counts['unique_events'] - len(samples),
                'truncated': truncated, 'log_retention_verified': False,
                'measurement_status': ('validated_metadata_emissions' if events
                                       else 'no_validated_metadata_emissions'),
                'coverage': COVERAGE}}


class _BoundedReader:
    def __init__(self, streams, limit):
        self.streams = streams
        self.remaining = limit
        self.scanned_bytes = 0

    def _readline(self, stream):
        chunk = stream.readline(min(MAX_LINE_BYTES + 1, self.remaining))
        self.remaining -= len(chunk)
        self.scanned_bytes += len(chunk)
        return chunk

    def __iter__(self):
        for stream in self.streams:
            while self.remaining:
                line = self._readline(stream)
                if not line:
                    break
                if len(line) > MAX_LINE_BYTES and not line.endswith(b'\n'):
                    # Discard this physical line without creating fake new records
                    # from its continuation. Draining consumes the same byte budget.
                    while self.remaining:
                        chunk = self._readline(stream)
                        if not chunk or chunk.endswith(b'\n'):
                            break
                elif not line.endswith(b'\n') and not self.remaining:
                    # The scan stopped inside a line: never parse the partial JSON.
                    line = b''
                yield line


def collect_stream(stream, **limits):
    return _collect_streams([stream], **limits)


def _collect_streams(streams, *, max_lines=20000, max_events=MAX_EVENTS,
                     max_samples=20, max_scan_bytes=MAX_SCAN_BYTES):
    _validate_limits(max_lines, max_events, max_samples, max_scan_bytes)
    reader = _BoundedReader(streams, max_scan_bytes)
    result = collect_logs(reader, max_lines=max_lines, max_events=max_events,
                          max_samples=max_samples, max_scan_bytes=max_scan_bytes)
    result['metadata']['scanned_bytes'] = reader.scanned_bytes
    result['metadata']['truncated'] |= reader.remaining == 0
    return result


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError('Invalid arguments')


def main(argv=None, *, stdin=None):
    parser = _Parser(description=__doc__)
    parser.add_argument('--input', action='append', default=[], help='Explicit authorized local log; repeat at most 16 times')
    parser.add_argument('--output', help='Optional JSON file under docs/verification/artifacts; default stdout')
    parser.add_argument('--max-lines', default='20000')
    parser.add_argument('--max-events', default=str(MAX_EVENTS))
    parser.add_argument('--max-samples', default='20')
    parser.add_argument('--max-scan-bytes', default=str(MAX_SCAN_BYTES))
    try:
        args = parser.parse_args(argv)
        limits = {field: int(getattr(args, field)) for field in
                  ('max_lines', 'max_events', 'max_samples', 'max_scan_bytes')}
        _validate_limits(**limits)
        if len(args.input) > 16:
            raise ValueError('Too many inputs')
        output = Path(args.output).resolve() if args.output else None
        if output is not None and (output.suffix != '.json' or not output.is_relative_to(ARTIFACTS.resolve())):
            raise ValueError('Invalid output path')
        with ExitStack() as stack:
            streams = [stack.enter_context(Path(path).open('rb')) for path in args.input]
            if not streams:
                streams = [stdin if stdin is not None else sys.stdin.buffer]
            result = _collect_streams(streams, **limits)
        encoded = json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False) + '\n'
        if output is None:
            print(encoded, end='')
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(encoded, encoding='utf-8', newline='\n')
    except (ValueError, TypeError, KeyError, OSError, UnicodeError, OverflowError, RecursionError):
        print('STARTUP_COLLECTION_FAILED', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
