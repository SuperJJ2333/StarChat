"""Bounded NETMON TCP measurements; no DNS/TLS/HTTP claims."""
import argparse
from datetime import datetime, timedelta, timezone
import errno
import json
import math
import os
from pathlib import Path
import re
import socket
import tempfile
import time


# DNS was checked from both observers before this candidate was prepared.
# An origin migration requires an explicit reviewed change to this allowlist.
ORIGIN_IP = '207.56.8.8'
SECONDARY_IP = '13.229.60.153'
TARGETS = {'origin_tcp443': (ORIGIN_IP, 443, 3),
           'secondary_ssh22': (SECONDARY_IP, 22, 1)}
OBSERVERS = frozenset({'origin_server', 'mainland_observer'})
ERRORS = frozenset({'connect_timeout', 'connection_refused', 'unreachable',
                    'permission_denied', 'socket_failure'})
WINDOW_ATTEMPTS = 60
ATTEMPTS_PER_MINUTE = 3
RETENTION_DAYS = 7
MAX_DAILY_LOG_BYTES = 2 * 1024 * 1024
MAX_STATE_BYTES = 4096
RESULT_FIELDS = frozenset({'target', 'observer', 'success', 'tcp_connect_ms',
                           'attempt_elapsed_ms', 'error', 'attempt_count'})


def _validate_options(origin_ip, observer, timeout_seconds, target='origin_tcp443'):
    if (target not in TARGETS or origin_ip != TARGETS[target][0]
            or observer not in OBSERVERS
            or (target == 'secondary_ssh22' and observer != 'origin_server')):
        raise ValueError('Only verified origin and fixed observer labels are allowed')
    if (type(timeout_seconds) not in (int, float) or not math.isfinite(timeout_seconds)
            or not 0 < timeout_seconds <= 3):
        raise ValueError('TCP timeout must be finite and at most three seconds')


def _error(exc):
    if isinstance(exc, TimeoutError) or exc.errno in (errno.ETIMEDOUT, 10060):
        return 'connect_timeout'
    if isinstance(exc, ConnectionRefusedError) or exc.errno in (errno.ECONNREFUSED, 10061):
        return 'connection_refused'
    if exc.errno in (errno.ENETUNREACH, errno.EHOSTUNREACH, 10051, 10065):
        return 'unreachable'
    if isinstance(exc, PermissionError) or exc.errno in (errno.EACCES, errno.EPERM, 10013):
        return 'permission_denied'
    return 'socket_failure'


def connect_once(origin_ip, observer, *, timeout_seconds=3.0,
                 socket_factory=socket.socket, clock=time.perf_counter_ns,
                 target='origin_tcp443'):
    _validate_options(origin_ip, observer, timeout_seconds, target)
    started = clock()
    error = None
    connected_elapsed = None
    try:
        # Literal IPv4 + AF_INET avoids DNS and tests TCP independently of TLS.
        with socket_factory(socket.AF_INET, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout_seconds)
            connect_started = clock()
            try:
                connection.connect((origin_ip, TARGETS[target][1]))
            finally:
                connected_elapsed = clock() - connect_started
    except OSError as exc:
        error = _error(exc)
    elapsed = clock() - started
    if elapsed < 0 or (connected_elapsed is not None and connected_elapsed < 0):
        raise ValueError('Monotonic elapsed time cannot be negative')
    elapsed_ms = round(elapsed / 1_000_000, 3)
    return {'target': target, 'observer': observer, 'success': error is None,
            'tcp_connect_ms': round(connected_elapsed / 1_000_000, 3) if error is None else None,
            'attempt_elapsed_ms': elapsed_ms, 'error': error, 'attempt_count': 1}


def probe_window(origin_ip, observer, *, attempts=None, target='origin_tcp443', **options):
    _validate_options(origin_ip, observer, options.get('timeout_seconds', 3.0), target)
    maximum = TARGETS[target][2]
    attempts = maximum if attempts is None else attempts
    if type(attempts) is not int or not 1 <= attempts <= maximum:
        raise ValueError('At most three attempts may run per scheduled invocation')
    return [connect_once(origin_ip, observer, target=target, **options) for _ in range(attempts)]


def summarize(history):
    if len(history) > WINDOW_ATTEMPTS or any(type(value) is not bool for value in history):
        raise ValueError('History must be bounded actual attempt outcomes')
    successes = sum(history)
    return {'attempts': len(history), 'successes': successes,
            'success_rate_percent': round(successes * 100 / len(history), 3) if history else None}


def _validate_result(result):
    if not isinstance(result, dict) or set(result) != RESULT_FIELDS:
        raise ValueError('Only closed TCP result fields are accepted')
    if (result['target'] not in TARGETS or result['observer'] not in OBSERVERS
            or (result['target'] == 'secondary_ssh22' and result['observer'] != 'origin_server')
            or type(result['success']) is not bool or type(result['attempt_count']) is not int
            or result['attempt_count'] != 1):
        raise ValueError('Invalid fixed result labels')
    for name in ('attempt_elapsed_ms', 'tcp_connect_ms'):
        value = result[name]
        if name == 'tcp_connect_ms' and value is None and not result['success']:
            continue
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
            raise ValueError('Invalid measured duration')
    if result['success']:
        if result['error'] is not None or result['tcp_connect_ms'] > result['attempt_elapsed_ms']:
            raise ValueError('Inconsistent successful measurement')
    elif result['error'] not in ERRORS or result['tcp_connect_ms'] is not None:
        raise ValueError('Inconsistent failed measurement')


def _no_link(path):
    if path.is_symlink():
        raise ValueError('Monitor paths must not be symbolic links')


def _read_history(path, observer, target='origin_tcp443'):
    _no_link(path)
    if not path.exists():
        return [], False
    try:
        if path.stat().st_size > MAX_STATE_BYTES:
            return [], True
        value = json.loads(path.read_text(encoding='utf-8'))
        expected = {'schema', 'observer', 'history'} if target == 'origin_tcp443' else {'schema', 'target', 'observer', 'history'}
        schema = 1 if target == 'origin_tcp443' else 2
        if (not isinstance(value, dict) or set(value) != expected
                or value['schema'] != schema or value['observer'] != observer
                or (schema == 2 and value['target'] != target)
                or not isinstance(value['history'], list)):
            return [], True
        summarize(value['history'])
        return value['history'], False
    except (ValueError, UnicodeError):
        return [], True


def _save_state(path, value):
    _no_link(path)
    fd, temporary = tempfile.mkstemp(prefix='state-', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(value, output, separators=(',', ':'))
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _prune_logs(directory, day):
    owned = []
    cutoff = day - timedelta(days=RETENTION_DAYS - 1)
    for path in directory.glob('tcp-????-??-??.jsonl'):
        if not re.fullmatch(r'tcp-\d{4}-\d{2}-\d{2}\.jsonl', path.name):
            continue
        _no_link(path)
        try:
            log_day = datetime.strptime(path.name[4:14], '%Y-%m-%d').date()
        except ValueError:
            continue
        if log_day < cutoff:
            path.unlink()
        else:
            owned.append(path)
    # Also bounded when the wall clock changes; durations remain monotonic.
    for path in sorted(owned, key=lambda value: value.name, reverse=True)[RETENTION_DAYS:]:
        path.unlink()


def record(directory, result, timestamp):
    _validate_result(result)
    if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', timestamp):
        raise ValueError('Only fixed UTC timestamp format is allowed')
    observed_at = datetime.strptime(timestamp, '%Y-%m-%dT%H:%M:%SZ')
    directory = Path(directory)
    _no_link(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = directory / 'state.json'
    history, reset = _read_history(state, result['observer'], result['target'])
    history = (history + [result['success']])[-WINDOW_ATTEMPTS:]
    report = {'schema': 1, 'timestamp': timestamp, **result,
              'window': summarize(history), 'state_reset': reset, 'log_capped': False}
    saved = {'schema': 1, 'observer': result['observer'], 'history': history}
    if result['target'] != 'origin_tcp443':
        saved.update(schema=2, target=result['target'])
    _save_state(state, saved)
    path = directory / f'tcp-{observed_at:%Y-%m-%d}.jsonl'
    _no_link(path)
    line = json.dumps(report, separators=(',', ':'), allow_nan=False) + '\n'
    size = path.stat().st_size if path.exists() else 0
    if size + len(line.encode('utf-8')) <= MAX_DAILY_LOG_BYTES:
        with path.open('a', encoding='utf-8') as output:
            output.write(line)
        os.chmod(path, 0o600)
    else:
        report['log_capped'] = True
    _prune_logs(directory, observed_at.date())
    return report


def percentiles(values):
    if not values:
        return {'p50': None, 'p95': None, 'p99': None, 'max': None}
    ordered = sorted(values)
    return {**{f'p{q}': ordered[math.ceil(len(ordered) * q / 100) - 1]
               for q in (50, 95, 99)}, 'max': ordered[-1]}


def minute_coverage(timestamps, start, end, attempts_per_minute):
    begin = datetime.strptime(start, '%Y-%m-%dT%H:%M:%SZ').replace(second=0)
    finish = datetime.strptime(end, '%Y-%m-%dT%H:%M:%SZ').replace(second=0)
    minutes = int((finish - begin).total_seconds() / 60) + 1
    if not 1 <= minutes <= 7 * 24 * 60 or attempts_per_minute not in (1, 3):
        raise ValueError('Coverage interval must be bounded to seven days')
    counts = {}
    for timestamp in timestamps:
        minute = datetime.strptime(timestamp, '%Y-%m-%dT%H:%M:%SZ').replace(second=0)
        if begin <= minute <= finish:
            counts[minute] = counts.get(minute, 0) + 1
    return {'expected_minutes': minutes, 'observed_minutes': len(counts),
            'missing_minutes': minutes - len(counts),
            'partial_minutes': sum(count < attempts_per_minute for count in counts.values()),
            'missing_attempts_in_observed_minutes': sum(max(0, attempts_per_minute - count) for count in counts.values()),
            'extra_attempt_minutes': sum(count > attempts_per_minute for count in counts.values())}


def coverage_summary(records, start, end, *, attempts_per_minute=3):
    if len(records) > 7 * 24 * 60 * 3:
        raise ValueError('Too many records')
    selected = [row for row in records if start <= row['timestamp'] <= end]
    for row in selected:
        _validate_result({name: row[name] for name in RESULT_FIELDS})
    if len({(row['target'], row['observer']) for row in selected}) > 1:
        raise ValueError('Coverage must be for one target and observer')
    summary = summarize_unbounded([row['success'] for row in selected])
    return {**minute_coverage([row['timestamp'] for row in selected], start, end, attempts_per_minute),
            **summary, 'failures': summary['attempts'] - summary['successes'],
            'duration_ms': percentiles([row['tcp_connect_ms'] for row in selected if row['success']])}


def summarize_unbounded(history):
    successes = sum(history)
    return {'attempts': len(history), 'successes': successes,
            'success_rate_percent': round(successes * 100 / len(history), 3) if history else None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin-ip', required=True, choices=[ORIGIN_IP, SECONDARY_IP])
    parser.add_argument('--target', choices=sorted(TARGETS), default='origin_tcp443')
    parser.add_argument('--observer', required=True, choices=sorted(OBSERVERS))
    parser.add_argument('--state-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        results = probe_window(args.origin_ip, args.observer, target=args.target)
        report = None
        for result in results:
            timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            report = record(args.state_dir, result, timestamp)
        print(json.dumps({'schema': 1, 'target': args.target, 'observer': args.observer,
                          'probe_window': summarize([value['success'] for value in results]),
                          'attempts': results, 'rolling_window': report['window'],
                          'state_reset': report['state_reset'], 'log_capped': report['log_capped']},
                         separators=(',', ':'), allow_nan=False))
        return 0
    except (OSError, ValueError):
        print(json.dumps({'schema': 1, 'observer': args.observer,
                          'monitor_error': 'storage_or_measurement_failure'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
