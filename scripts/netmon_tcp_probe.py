"""Bounded NETMON extension: actual TCP443 connect, no DNS/TLS/HTTP claims."""
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


def _validate_options(origin_ip, observer, timeout_seconds):
    if origin_ip != ORIGIN_IP or observer not in OBSERVERS:
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
                 socket_factory=socket.socket, clock=time.perf_counter_ns):
    _validate_options(origin_ip, observer, timeout_seconds)
    started = clock()
    error = None
    connected_elapsed = None
    try:
        # Literal IPv4 + AF_INET avoids DNS and tests TCP independently of TLS.
        with socket_factory(socket.AF_INET, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout_seconds)
            connect_started = clock()
            try:
                connection.connect((origin_ip, 443))
            finally:
                connected_elapsed = clock() - connect_started
    except OSError as exc:
        error = _error(exc)
    elapsed = clock() - started
    if elapsed < 0 or (connected_elapsed is not None and connected_elapsed < 0):
        raise ValueError('Monotonic elapsed time cannot be negative')
    elapsed_ms = round(elapsed / 1_000_000, 3)
    return {'target': 'origin_tcp443', 'observer': observer, 'success': error is None,
            'tcp_connect_ms': round(connected_elapsed / 1_000_000, 3) if error is None else None,
            'attempt_elapsed_ms': elapsed_ms, 'error': error, 'attempt_count': 1}


def probe_window(origin_ip, observer, *, attempts=ATTEMPTS_PER_MINUTE, **options):
    if type(attempts) is not int or not 1 <= attempts <= ATTEMPTS_PER_MINUTE:
        raise ValueError('At most three attempts may run per scheduled invocation')
    return [connect_once(origin_ip, observer, **options) for _ in range(attempts)]


def summarize(history):
    if len(history) > WINDOW_ATTEMPTS or any(type(value) is not bool for value in history):
        raise ValueError('History must be bounded actual attempt outcomes')
    successes = sum(history)
    return {'attempts': len(history), 'successes': successes,
            'success_rate_percent': round(successes * 100 / len(history), 3) if history else None}


def _validate_result(result):
    if not isinstance(result, dict) or set(result) != RESULT_FIELDS:
        raise ValueError('Only closed TCP result fields are accepted')
    if (result['target'] != 'origin_tcp443' or result['observer'] not in OBSERVERS
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


def _read_history(path, observer):
    _no_link(path)
    if not path.exists():
        return [], False
    try:
        if path.stat().st_size > MAX_STATE_BYTES:
            return [], True
        value = json.loads(path.read_text(encoding='utf-8'))
        if (not isinstance(value, dict) or set(value) != {'schema', 'observer', 'history'}
                or value['schema'] != 1 or value['observer'] != observer
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
    history, reset = _read_history(state, result['observer'])
    history = (history + [result['success']])[-WINDOW_ATTEMPTS:]
    report = {'schema': 1, 'timestamp': timestamp, **result,
              'window': summarize(history), 'state_reset': reset, 'log_capped': False}
    _save_state(state, {'schema': 1, 'observer': result['observer'], 'history': history})
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--origin-ip', required=True, choices=[ORIGIN_IP])
    parser.add_argument('--observer', required=True, choices=sorted(OBSERVERS))
    parser.add_argument('--state-dir', required=True, type=Path)
    args = parser.parse_args()
    try:
        results = probe_window(args.origin_ip, args.observer)
        report = None
        for result in results:
            timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            report = record(args.state_dir, result, timestamp)
        print(json.dumps({'schema': 1, 'target': 'origin_tcp443', 'observer': args.observer,
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
