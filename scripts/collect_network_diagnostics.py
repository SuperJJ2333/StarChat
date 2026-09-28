"""Collect only validated network summaries over the existing strict SSH jumper."""
from __future__ import annotations

import argparse
import base64
import inspect
import json
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'docs/verification/artifacts'
CONTAINER = 'starchat-business-api-1'
MAX_LINE_BYTES = 65536
MAX_EXPORT_BYTES = 16 * 1024 * 1024
MAX_EXPORTED_SAMPLES = 20000
COUNTERS = ('http_2xx', 'http_3xx', 'http_4xx', 'http_5xx', 'network_errors', 'timeouts', 'cancelled')
NETWORK_FIELDS = {'sample_id', 'version', 'platform', 'window_start', 'window_end',
                  'target', 'network', 'attempts', 'success_latency_buckets', *COUNTERS}
NETWORK_TYPES = {'unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other'}
UUID_PATTERN = r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
VERSION_PATTERN = r'\d{1,4}\.\d{1,4}\.\d{1,4}(?:\+\d{1,8})?'
UTC_PATTERN = r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)'
STAGES = {'sendAdmission', 'matrixSend', 'historyLoad', 'historySearch', 'dateMonth',
          'dateLocate', 'scrollAnchor', 'framework', 'pending_write_failed',
          'request_uncertain', 'result_write_failed', 'retry_recovered',
          'terminal_invalidated', 'result_superseded', 'network_request',
          'matrix_sync_soft_kick', 'matrix_sync_hard_restart'}
WATCHDOG_STAGES = {'matrix_sync_soft_kick', 'matrix_sync_hard_restart'}
WATCHDOG_ERRORS = {'slow', 'timeout', 'unknown', 'recovered'}
ERRORS = {'slow', 'network', 'timeout', 'rejected', 'cancelled', 'incomplete', 'unknown', 'recovered'}
COVERAGE = ['Only bounded retained container logs were scanned; retention is unverified',
            'No valid summaries does not imply no requests or no failures',
            'Discarded operations are checked only for object-list structure and shared record budget; performance semantics are not revalidated',
            'Summaries exceeding export byte or sample limits are counted but omitted',
            'Client release and compatible receiver are required before starting a new observation window']


def uint(value, low=0, high=1000000):
    return type(value) is int and low <= value <= high


def valid_version(value):
    return isinstance(value, str) and len(value) <= 32 and re.fullmatch(VERSION_PATTERN, value) is not None


def utc(value):
    if not isinstance(value, str) or not re.fullmatch(UTC_PATTERN, value):
        raise ValueError('Invalid UTC time')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def sanitize_network(row):
    if not isinstance(row, dict) or set(row) != NETWORK_FIELDS:
        raise ValueError('Invalid closed summary')
    if (not isinstance(row['sample_id'], str) or not re.fullmatch(UUID_PATTERN, row['sample_id'])
            or not valid_version(row['version']) or row['platform'] not in ('android', 'ios', 'other')
            or row['target'] != 'primary_api' or row['network'] not in NETWORK_TYPES):
        raise ValueError('Invalid closed metadata')
    if utc(row['window_start']) > utc(row['window_end']):
        raise ValueError('Invalid time window')
    if (not uint(row['attempts'], 1) or any(not uint(row[field]) for field in COUNTERS)
            or sum(row[field] for field in COUNTERS) != row['attempts']):
        raise ValueError('Invalid outcome counts')
    buckets = row['success_latency_buckets']
    if (not isinstance(buckets, list) or len(buckets) != 9
            or any(not uint(value) for value in buckets) or sum(buckets) != row['http_2xx']):
        raise ValueError('Invalid latency buckets')
    # Return only enumerated fields; retain the original identity and UTC window.
    return {field: row[field] for field in sorted(NETWORK_FIELDS)}


def validate_legacy_fields(row):
    # Unset defaults are absent from the receiver's exclude_unset stdout.
    events = row.get('events', [])
    if not isinstance(events, list) or len(events) > 20:
        raise ValueError('Invalid events')
    required = {'operation_id', 'stage', 'error', 'elapsed_ms', 'count'}
    allowed = required | {'status', 'retry_count', 'lifecycle'}
    for event in events:
        if not isinstance(event, dict) or not required <= set(event) <= allowed:
            raise ValueError('Invalid event fields')
        if (not isinstance(event['operation_id'], str) or not re.fullmatch(UUID_PATTERN, event['operation_id'])
                or event['stage'] not in STAGES or event['error'] not in ERRORS
                or not uint(event['elapsed_ms'], high=3600000) or not uint(event['count'], 1)):
            raise ValueError('Invalid event metadata')
        if event['stage'] in WATCHDOG_STAGES and event['error'] not in WATCHDOG_ERRORS:
            raise ValueError('Invalid watchdog outcome')
        if event.get('status') is not None and not uint(event['status'], 100, 599):
            raise ValueError('Invalid status')
        if event.get('retry_count') is not None and not uint(event['retry_count'], high=20):
            raise ValueError('Invalid retry count')
        if event.get('lifecycle') not in (None, 'foreground', 'background', 'unknown'):
            raise ValueError('Invalid lifecycle')
    # This is a network-only collector, not a second performance receiver.
    # Bound the discarded list and shared budget; never copy, format or export
    # any operation value, including unknown or private nested metadata.
    operations = row.get('operations', [])
    requests = row.get('network_requests', [])
    request_required = {'request_id', 'version', 'platform', 'target', 'network',
                        'method', 'endpoint_category', 'started_at', 'elapsed_ms',
                        'phase', 'reason'}
    request_optional = {'operation_id', 'headers_ms', 'http_status',
                        'timeout_budget_ms', 'timeout_lateness_ms'}
    if (not isinstance(requests, list) or len(requests) > 8
            or any(not isinstance(item, dict)
                   or not request_required <= set(item) <= request_required | request_optional
                   for item in requests)):
        raise ValueError('Invalid discarded request structure')
    if (not isinstance(operations, list) or len(operations) > 20
            or any(not isinstance(item, dict) for item in operations)
            or len(events) + len(operations) + len(requests) > 20):
        raise ValueError('Invalid discarded operation structure or record budget')
    frames = row.get('frames')
    if frames is not None:
        names = {'frame_count', 'slow_frame_count', 'slow_build_count', 'slow_raster_count'}
        if not isinstance(frames, dict) or set(frames) != names or any(not uint(frames[key]) for key in names):
            raise ValueError('Invalid frames')
        total, slow = frames['frame_count'], frames['slow_frame_count']
        build, raster = frames['slow_build_count'], frames['slow_raster_count']
        if total < 1 or not max(build, raster) <= slow <= min(total, build + raster):
            raise ValueError('Invalid frame counts')
    loss = row.get('diagnostic_loss')
    if 'diagnostic_loss' in row:
        counters = {'dropped_events', 'dropped_operations', 'dropped_frames'}
        if (not isinstance(loss, dict) or set(loss) != counters | {'sample_id'}
                or not isinstance(loss['sample_id'], str)
                or not re.fullmatch(UUID_PATTERN, loss['sample_id'])
                or any(not uint(loss[key]) for key in counters)
                or not any(loss[key] for key in counters)):
            raise ValueError('Invalid diagnostic loss')
    if 'frame_windows' in row:
        windows = row['frame_windows']
        names = {'window_id', 'window_start', 'window_end', 'active_tab',
                 'budget_us', 'frame_count', 'slow_frame_count',
                 'slow_build_count', 'slow_raster_count', 'max_build_us',
                 'max_raster_us'}
        if not isinstance(windows, list) or not 1 <= len(windows) <= 8:
            raise ValueError('Invalid frame windows')
        ids = set()
        for window in windows:
            if not isinstance(window, dict) or set(window) != names:
                raise ValueError('Invalid frame window fields')
            window_id = window['window_id']
            if (not isinstance(window_id, str) or not re.fullmatch(UUID_PATTERN, window_id)
                    or window_id in ids or utc(window['window_start']) > utc(window['window_end'])
                    or window['active_tab'] not in ('unknown', 'messages', 'contacts', 'discover', 'me')
                    or not uint(window['budget_us'], 1)
                    or not uint(window['frame_count'], 1)
                    or not uint(window['max_build_us'], high=3600000000)
                    or not uint(window['max_raster_us'], high=3600000000)):
                raise ValueError('Invalid frame window metadata')
            ids.add(window_id)
            slow = window['slow_frame_count']
            build, raster = window['slow_build_count'], window['slow_raster_count']
            if (not all(uint(value) for value in (slow, build, raster))
                    or not max(build, raster) <= slow <= min(window['frame_count'], build + raster)):
                raise ValueError('Invalid frame window counts')


def sanitize_record(row):
    required = {'event', 'version', 'platform'}
    if (not isinstance(row, dict) or not required <= set(row) <= required | {
            'events', 'operations', 'frames', 'networks', 'network_requests',
            'diagnostic_loss', 'frame_windows', 'subject_ref', 'device_ref'}):
        raise ValueError('Invalid envelope')
    for key in ('subject_ref', 'device_ref'):
        if key in row and (not isinstance(row[key], str)
                           or re.fullmatch(r'[0-9a-f]{64}', row[key]) is None):
            raise ValueError('Invalid diagnostic reference')
    if (row['event'] != 'client_diagnostics' or not valid_version(row['version'])
            or row['platform'] not in ('android', 'ios', 'other')):
        raise ValueError('Invalid envelope metadata')
    validate_legacy_fields(row)
    networks = row.get('networks')
    if networks is None or networks == []:
        return None
    if not isinstance(networks, list) or not 1 <= len(networks) <= 8:
        raise ValueError('Invalid networks batch')
    safe = [sanitize_network(item) for item in networks]
    if len({item['sample_id'] for item in safe}) != len(safe):
        raise ValueError('Duplicate sample identity')
    return {'event': 'client_diagnostics', 'networks': safe}


def validate_limits(since_hours, tail):
    if not uint(since_hours, 1, 72) or not uint(tail, 1, 100000):
        raise ValueError('Invalid scan limits')


def sanitize_logs(lines, since_hours=72, tail=20000):
    """Pure log filtering; never return original lines, errors or legacy payloads."""
    validate_limits(since_hours, tail)
    records = []
    counts = dict.fromkeys(('scanned_lines', 'exported_batches', 'exported_samples',
                            'exported_bytes', 'dropped_batches', 'rejected_lines',
                            'legacy_lines', 'ignored_lines', 'oversized_lines'), 0)
    iterator = iter(lines)
    for _ in range(tail):
        try:
            line = next(iterator)
        except StopIteration:
            break
        counts['scanned_lines'] += 1
        if not isinstance(line, (str, bytes)):
            counts['rejected_lines'] += 1
            continue
        if len(line if isinstance(line, bytes) else line.encode('utf-8')) > MAX_LINE_BYTES:
            counts['oversized_lines'] += 1
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict) or row.get('event') != 'client_diagnostics':
                counts['ignored_lines'] += 1
                continue
            safe = sanitize_record(row)
            if safe is None:
                counts['legacy_lines'] += 1
                continue
            size = len((json.dumps(safe, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8'))
            if (counts['exported_samples'] + len(safe['networks']) > MAX_EXPORTED_SAMPLES
                    or counts['exported_bytes'] + size > MAX_EXPORT_BYTES):
                counts['dropped_batches'] += 1
                continue
            records.append(safe)
            counts['exported_batches'] += 1
            counts['exported_samples'] += len(safe['networks'])
            counts['exported_bytes'] += size
        except (ValueError, TypeError, KeyError, UnicodeError, OverflowError, RecursionError):
            counts['rejected_lines'] += 1
    return {'records': records, 'metadata': {
        'schema_version': 1, 'container': CONTAINER, 'since_hours': since_hours, 'tail_limit': tail,
        'max_export_bytes': MAX_EXPORT_BYTES, 'max_exported_samples': MAX_EXPORTED_SAMPLES,
        'collected_at': datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'), **counts,
        'truncated': counts['scanned_lines'] >= tail or counts['dropped_batches'] > 0,
        'export_limit_reached': counts['dropped_batches'] > 0,
        'truncation_semantics': 'Conservative: tail reached or validated summaries exceed export limits',
        'log_retention_verified': False,
        'measurement_status': ('export_limited' if counts['dropped_batches'] else
                               'valid_network_summaries' if records else 'no_valid_network_summaries'),
        'coverage': COVERAGE}}


# The reviewed program is transferred in memory, never written to the remote host.
# Docker output stays remote; only the closed filter results cross the SSH stream.
_REMOTE_DRIVER = '''
import signal
import subprocess

def _bounded_lines(stream):
    while True:
        line = stream.readline(MAX_LINE_BYTES + 1)
        if not line:
            break
        if len(line) > MAX_LINE_BYTES and not line.endswith(b'\\n'):
            while True:
                chunk = stream.readline(MAX_LINE_BYTES + 1)
                if not chunk or chunk.endswith(b'\\n'):
                    break
        yield line

def _remote_main(since_hours, tail):
    process = None
    try:
        validate_limits(since_hours, tail)
        signal.signal(signal.SIGALRM, lambda *args: (_ for _ in ()).throw(TimeoutError()))
        signal.alarm(60)
        process = subprocess.Popen(['docker', 'logs', '--since', str(since_hours) + 'h',
                                    '--tail', str(tail), CONTAINER],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        result = sanitize_logs(_bounded_lines(process.stdout), since_hours, tail)
        if result['metadata']['scanned_lines'] >= tail and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        elif process.wait(timeout=5) != 0:
            raise ValueError('Docker log read failed')
        for row in result['records']:
            print(json.dumps(row, ensure_ascii=True, separators=(',', ':'), allow_nan=False))
        print(json.dumps({'collection_metadata': result['metadata']}, ensure_ascii=True, allow_nan=False))
        return 0
    except Exception:
        print('NETWORK_COLLECTION_REMOTE_FAILED', file=sys.stderr)
        return 1
    finally:
        signal.alarm(0)
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
'''


def remote_program():
    constants = {name: globals()[name] for name in ('CONTAINER', 'MAX_LINE_BYTES', 'MAX_EXPORT_BYTES', 'MAX_EXPORTED_SAMPLES', 'COUNTERS',
                 'NETWORK_FIELDS', 'NETWORK_TYPES', 'UUID_PATTERN', 'VERSION_PATTERN',
                 'UTC_PATTERN', 'STAGES', 'ERRORS', 'COVERAGE')}
    declarations = '\n'.join(f'{name} = {value!r}' for name, value in constants.items())
    functions = '\n'.join(inspect.getsource(function) for function in
                          (uint, valid_version, utc, sanitize_network, validate_legacy_fields,
                           sanitize_record, validate_limits, sanitize_logs))
    return 'import json, re, sys\nfrom datetime import datetime, timezone\n' + declarations + '\n' + functions + _REMOTE_DRIVER


REMOTE_PROGRAM = remote_program()


def collection_command(since_hours=72, tail=20000):
    validate_limits(since_hours, tail)
    program = REMOTE_PROGRAM + f'\nraise SystemExit(_remote_main({since_hours}, {tail}))\n'
    encoded = base64.b64encode(program.encode('utf-8')).decode('ascii')
    bootstrap = f'import base64;exec(base64.b64decode("{encoded}").decode("utf-8"))'
    command = 'python3 -c ' + shlex.quote(bootstrap)
    return ['pwsh.exe', '-NoProfile', '-File', str(ROOT / 'scripts/starchat-server.ps1'),
            '-Action', 'Command', '-RemoteCommand', command]


def decode_result(wire, since_hours, tail):
    rows, metadata, exported_bytes, exported_samples = [], None, 0, 0
    for line in wire.splitlines():
        if not line.strip():
            continue
        if len(line.encode('utf-8')) > MAX_LINE_BYTES or len(rows) > tail:
            raise ValueError('Invalid remote output')
        row = json.loads(line)
        if not isinstance(row, dict):
            raise ValueError('Invalid remote output')
        if set(row) == {'collection_metadata'}:
            if metadata is not None:
                raise ValueError('Duplicate metadata')
            metadata = row['collection_metadata']
            continue
        if metadata is not None or set(row) != {'event', 'networks'} or row['event'] != 'client_diagnostics':
            raise ValueError('Invalid export envelope')
        networks = row['networks']
        if not isinstance(networks, list) or not 1 <= len(networks) <= 8:
            raise ValueError('Invalid exported networks')
        safe = [sanitize_network(item) for item in networks]
        if len({item['sample_id'] for item in safe}) != len(safe):
            raise ValueError('Duplicate sample')
        safe_row = {'event': 'client_diagnostics', 'networks': safe}
        exported_bytes += len((json.dumps(safe_row, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8'))
        exported_samples += len(safe)
        if exported_bytes > MAX_EXPORT_BYTES or exported_samples > MAX_EXPORTED_SAMPLES:
            raise ValueError('Export limits exceeded')
        rows.append(safe_row)
    if not isinstance(metadata, dict):
        raise ValueError('Missing collection metadata')
    expected = sanitize_logs([], since_hours, tail)['metadata']
    if set(metadata) != set(expected):
        raise ValueError('Invalid collection metadata fields')
    for key in ('schema_version', 'container', 'since_hours', 'tail_limit', 'max_export_bytes',
                'max_exported_samples', 'truncation_semantics',
                'log_retention_verified', 'coverage'):
        if type(metadata[key]) is not type(expected[key]) or metadata[key] != expected[key]:
            raise ValueError('Invalid collection metadata')
    utc(metadata['collected_at'])
    for key in ('scanned_lines', 'exported_batches', 'dropped_batches', 'rejected_lines', 'legacy_lines', 'ignored_lines', 'oversized_lines'):
        if not uint(metadata[key], high=tail):
            raise ValueError('Invalid collection counts')
    if (not uint(metadata['exported_samples'], high=min(tail * 8, MAX_EXPORTED_SAMPLES))
            or not uint(metadata['exported_bytes'], high=MAX_EXPORT_BYTES)
            or metadata['exported_bytes'] != exported_bytes
            or metadata['exported_batches'] != len(rows)
            or metadata['exported_samples'] != exported_samples
            or metadata['scanned_lines'] != sum(metadata[key] for key in
                ('exported_batches', 'dropped_batches', 'rejected_lines', 'legacy_lines', 'ignored_lines', 'oversized_lines'))
            or type(metadata['truncated']) is not bool
            or metadata['truncated'] != (metadata['scanned_lines'] >= tail or metadata['dropped_batches'] > 0)
            or type(metadata['export_limit_reached']) is not bool
            or metadata['export_limit_reached'] != (metadata['dropped_batches'] > 0)
            or metadata['measurement_status'] != ('export_limited' if metadata['dropped_batches'] else
                'valid_network_summaries' if rows else 'no_valid_network_summaries')):
        raise ValueError('Inconsistent collection metadata')
    return rows, metadata


def main(argv=None, runner=subprocess.run):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--since-hours', type=int, default=72)
    parser.add_argument('--tail', type=int, default=20000)
    args = parser.parse_args(argv)
    try:
        validate_limits(args.since_hours, args.tail)
        output = args.output.resolve()
        artifacts = ARTIFACTS.resolve()
        if not output.is_relative_to(artifacts) or output == artifacts or output.suffix != '.jsonl':
            raise ValueError('Invalid output path')
        metadata_path = output.with_suffix('.meta.json').resolve()
        if not metadata_path.is_relative_to(artifacts) or metadata_path == artifacts:
            raise ValueError('Invalid metadata path')
    except (ValueError, TypeError, OSError):
        parser.error('Invalid scan bounds or artifact output path; no connection attempted')
    try:
        process = runner(collection_command(args.since_hours, args.tail), capture_output=True,
                         text=True, encoding='utf-8', timeout=90, check=False)
        if process.returncode != 0:
            raise ValueError('Remote collection failed')
        rows, metadata = decode_result(process.stdout, args.since_hours, args.tail)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(''.join(json.dumps(row, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n'
                                  for row in rows), encoding='utf-8', newline='\n')
        output.with_suffix('.meta.json').write_text(json.dumps(metadata, ensure_ascii=True, indent=2, allow_nan=False) + '\n',
                                                   encoding='utf-8', newline='\n')
    except (ValueError, TypeError, KeyError, OSError, UnicodeError, OverflowError, subprocess.TimeoutExpired):
        print('NETWORK_COLLECTION_FAILED: no valid collection result', file=sys.stderr)
        return 1
    print(json.dumps({'output': str(output), 'metadata': str(output.with_suffix('.meta.json')),
                      'scanned_lines': metadata['scanned_lines'], 'exported_samples': metadata['exported_samples'],
                      'truncated': metadata['truncated'], 'measurement_status': metadata['measurement_status']}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
