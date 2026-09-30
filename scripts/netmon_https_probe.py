"""Bounded NETMON HTTPS observers, fixed public endpoints, verified TLS only.

Curl phase deltas describe this observer's requests, never Flutter requests.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

import netmon_tcp_probe as tcp


DOMAIN = 'liuhetong888.com'
TARGETS = {'business_dns': ('/api/v1/health/ready', False),
           'business_ipv4_pinned': ('/api/v1/health/ready', True),
           'matrix_dns': ('/_matrix/client/versions', False),
           'matrix_ipv4_pinned': ('/_matrix/client/versions', True)}
ATTEMPTS = 3
CONNECT_SECONDS = 3
REQUEST_SECONDS = 6
WINDOW_SECONDS = 30
MAX_DAILY_LOG_BYTES = 16 * 1024 * 1024
CONSECUTIVE_FAILURE_ROUNDS = 3
TCP_P95_WARNING_MS = 1000
FIELDS = frozenset({'target', 'observer', 'success', 'curl_exit', 'http_status',
                    'dns_ms', 'tcp_connect_ms', 'tls_ms', 'ttfb_ms', 'total_ms',
                    'certificate_validated', 'error', 'failure_stage', 'monitor_error'})
FORMAT = '%{http_code}|%{time_namelookup}|%{time_connect}|%{time_appconnect}|%{time_starttransfer}|%{time_total}|%{ssl_verify_result}'
CURL = r'C:\Windows\System32\curl.exe' if os.name == 'nt' else '/usr/bin/curl'
NETWORK_ERRORS = frozenset({'dns_failure', 'socket_failure', 'tls_failure', 'request_timeout',
                            'server_5xx', 'rate_limit', 'auth_failure', 'http_rejection'})
STAGES = ('dns', 'tcp', 'tls', 'response')


def _empty(target, observer):
    return {'target': target, 'observer': observer, 'success': None, 'curl_exit': None,
            'http_status': None, 'dns_ms': None, 'tcp_connect_ms': None, 'tls_ms': None,
            'ttfb_ms': None, 'total_ms': None, 'certificate_validated': None,
            'error': None, 'failure_stage': None, 'monitor_error': None}


def probe_once(target, observer, *, runner=subprocess.run, max_seconds=REQUEST_SECONDS):
    if (target not in TARGETS or observer not in tcp.OBSERVERS
            or type(max_seconds) not in (int, float) or not math.isfinite(max_seconds)
            or not 0 < max_seconds <= REQUEST_SECONDS):
        raise ValueError('Only fixed targets/observers and bounded deadlines allowed')
    result = _empty(target, observer)
    endpoint, pinned = TARGETS[target]
    command = [CURL, '--disable', '--noproxy', '*', '--connect-timeout', str(min(CONNECT_SECONDS, max_seconds)),
               '--max-time', str(max_seconds), '--silent', '--output', os.devnull,
               '--write-out', FORMAT, '--proto', '=https']
    if pinned:
        command += ['--resolve', f'{DOMAIN}:443:{tcp.ORIGIN_IP}']
    command += [f'https://{DOMAIN}{endpoint}']
    try:
        process = runner(command, capture_output=True, text=True, timeout=max_seconds + 0.2,
                         check=False, encoding='utf-8')
    except subprocess.TimeoutExpired:
        # The watchdog interrupted curl: no valid curl stage measurements exist.
        result['monitor_error'] = 'process_deadline'
        return result
    except OSError:
        result['monitor_error'] = 'process_unavailable'
        return result
    try:
        if len(process.stdout) > 512 or type(process.returncode) is not int or not 0 <= process.returncode <= 255:
            raise ValueError('Invalid bounded measurement')
        parts = process.stdout.split('|')
        if len(parts) != 7 or not re.fullmatch(r'\d{3}', parts[0]) or not re.fullmatch(r'\d+', parts[6]):
            raise ValueError('Invalid fields')
        status = int(parts[0])
        dns, connected, tls, first, total = map(float, parts[1:6])
        if (any(not math.isfinite(value) or value < 0 for value in (dns, connected, tls, first, total))
                or status != 0 and not 100 <= status <= 599
                or any(value > total for value in (dns, connected, tls, first))
                or connected > 0 and connected < dns
                or tls > 0 and (connected <= 0 or tls < connected)
                or first > 0 and (tls <= 0 or first < tls)):
            raise ValueError('Invalid cumulative stages')
        if process.returncode == 0 and (status == 0 or first <= 0 or int(parts[6]) != 0):
            raise ValueError('Incomplete successful request')
    except (ValueError, TypeError, AttributeError):
        result['monitor_error'] = 'invalid_measurement'
        return result
    result.update(curl_exit=process.returncode, http_status=status or None,
                  total_ms=round(total * 1000, 3))
    # A resolved literal address bypasses DNS; its near-zero curl time is not DNS latency.
    result['dns_ms'] = round(dns * 1000, 3) if not pinned and dns > 0 else None
    if connected > 0:
        result['tcp_connect_ms'] = round((connected - dns) * 1000, 3)
    if tls > 0 and int(parts[6]) == 0:
        result['tls_ms'] = round((tls - connected) * 1000, 3)
        result['certificate_validated'] = True
    if first > 0:
        result['ttfb_ms'] = round((first - tls) * 1000, 3)
    result['success'] = process.returncode == 0 and 200 <= status < 300
    if not result['success']:
        if process.returncode == 6:
            error, stage = 'dns_failure', 'dns'
        elif process.returncode in (35, 51, 58, 60, 77, 80, 82, 83, 90, 91):
            error, stage = 'tls_failure', 'tls'
            result['certificate_validated'] = False if process.returncode == 60 else None
        elif process.returncode == 28:
            error = 'request_timeout'
            stage = 'response' if tls > 0 else 'tls' if connected > 0 else 'tcp' if pinned or dns > 0 else 'unknown'
        elif process.returncode != 0:
            error, stage = 'socket_failure', 'response' if first > 0 else 'tls' if connected > 0 else 'tcp'
        else:
            error = ('server_5xx' if status >= 500 else 'rate_limit' if status == 429
                     else 'auth_failure' if status in (401, 403) else 'http_rejection')
            stage = 'response'
        result.update(error=error, failure_stage=stage)
    return result


def probe_window(observer, *, runner=subprocess.run, clock=time.monotonic, on_result=None):
    if observer not in tcp.OBSERVERS:
        raise ValueError('Unapproved observer')
    deadline = clock() + WINDOW_SECONDS
    outcomes = []
    # Round-robin prevents a failing endpoint from consuming the whole window first.
    schedule = [target for _ in range(ATTEMPTS) for target in TARGETS]
    for target in schedule:
        remaining = deadline - clock()
        if remaining <= 0.25:
            break
        result = probe_once(target, observer, runner=runner,
                            max_seconds=min(REQUEST_SECONDS, remaining - 0.2))
        outcomes.append(result)
        if on_result is not None:
            on_result(result)
    return {'window_budget_seconds': WINDOW_SECONDS, 'attempts': outcomes,
            'budget_skipped_attempts': len(schedule) - len(outcomes)}


def _validate_result(result):
    if (not isinstance(result, dict) or set(result) != FIELDS or result['target'] not in TARGETS
            or result['observer'] not in tcp.OBSERVERS):
        raise ValueError('Closed result fields required')
    for name in ('dns_ms', 'tcp_connect_ms', 'tls_ms', 'ttfb_ms', 'total_ms'):
        value = result[name]
        if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or value < 0):
            raise ValueError('Invalid measured duration')
    if result['monitor_error'] not in (None, 'process_deadline', 'process_unavailable', 'invalid_measurement'):
        raise ValueError('Closed monitor error required')
    if result['monitor_error'] is not None:
        if result != {**_empty(result['target'], result['observer']), 'monitor_error': result['monitor_error']}:
            raise ValueError('Monitor failure cannot fabricate request results')
    elif (type(result['success']) is not bool or result['error'] not in NETWORK_ERRORS | {None}
          or result['failure_stage'] not in STAGES + ('unknown', None)
          or type(result['curl_exit']) is not int or not 0 <= result['curl_exit'] <= 255
          or result['http_status'] is not None and (type(result['http_status']) is not int or not 100 <= result['http_status'] <= 599)
          or result['certificate_validated'] is not None and type(result['certificate_validated']) is not bool
          or result['total_ms'] is None):
        raise ValueError('Invalid request result')
    if result['monitor_error'] is None:
        if result['success']:
            if (result['curl_exit'] != 0 or result['http_status'] is None
                    or not 200 <= result['http_status'] < 300 or result['error'] is not None
                    or result['failure_stage'] is not None or result['certificate_validated'] is not True
                    or any(result[key] is None for key in ('tcp_connect_ms', 'tls_ms', 'ttfb_ms'))):
                raise ValueError('Inconsistent successful request')
        elif result['error'] is None or result['failure_stage'] is None:
            raise ValueError('Failed request requires a closed error and observed stage')
        if (result['tls_ms'] is not None and (result['tcp_connect_ms'] is None or result['certificate_validated'] is not True)
                or result['ttfb_ms'] is not None and result['tls_ms'] is None):
            raise ValueError('Later stages require earlier completed stages')
    if result['target'].endswith('pinned') and result['dns_ms'] is not None:
        raise ValueError('Fixed origin has no DNS measurement')


def record(directory, result, timestamp):
    _validate_result(result)
    day = datetime.strptime(timestamp, '%Y-%m-%dT%H:%M:%SZ').date()
    directory = Path(directory)
    tcp._no_link(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    report = {'schema': 1, 'timestamp': timestamp, **result}
    path = directory / f'https-{day:%Y-%m-%d}.jsonl'
    tcp._no_link(path)
    line = json.dumps(report, separators=(',', ':'), allow_nan=False) + '\n'
    size = path.stat().st_size if path.exists() else 0
    capped = size + len(line.encode('utf-8')) > MAX_DAILY_LOG_BYTES
    if not capped:
        with path.open('a', encoding='utf-8') as output:
            output.write(line)
        os.chmod(path, 0o600)
    owned = []
    cutoff = day - timedelta(days=tcp.RETENTION_DAYS - 1)
    for log in directory.glob('https-????-??-??.jsonl'):
        tcp._no_link(log)
        try:
            observed = datetime.strptime(log.name[6:16], '%Y-%m-%d').date()
        except ValueError:
            continue
        if observed < cutoff:
            log.unlink()
        else:
            owned.append(log)
    for log in sorted(owned, key=lambda value: value.name, reverse=True)[tcp.RETENTION_DAYS:]:
        log.unlink()
    return {'log_capped': capped}


def summarize_samples(samples, start, end):
    if len(samples) > 7 * 24 * 60 * ATTEMPTS:
        raise ValueError('Summary must be bounded to seven days for one target')
    selected = [value for value in samples if start <= value['timestamp'] <= end]
    for value in selected:
        _validate_result({key: value[key] for key in FIELDS})
    if len({(value['target'], value['observer']) for value in selected}) > 1:
        raise ValueError('Each summary requires one target and observer')
    measured = [value for value in selected if value['monitor_error'] is None]
    successful = sum(value['success'] for value in measured)
    stages = {}
    for stage, field in zip(STAGES, ('dns_ms', 'tcp_connect_ms', 'tls_ms', 'ttfb_ms')):
        reached = [value for value in measured if value[field] is not None or value['failure_stage'] == stage]
        finished = [value[field] for value in reached if value[field] is not None]
        stages[stage] = {'attempts': len(reached), 'successes': len(finished),
                         'failures': len(reached) - len(finished),
                         'success_rate_percent': round(len(finished) * 100 / len(reached), 3) if reached else None,
                         'duration_ms': tcp.percentiles(finished)}
    minutes = {}
    for value in measured:
        minutes.setdefault(value['timestamp'][:16], []).append(value['success'])
    consecutive = maximum = 0
    previous = None
    for key, outcomes in sorted(minutes.items()):
        minute = datetime.strptime(key, '%Y-%m-%dT%H:%M')
        if previous is None or minute - previous != timedelta(minutes=1):
            consecutive = 0
        consecutive = consecutive + 1 if len(outcomes) == ATTEMPTS and not any(outcomes) else 0
        maximum = max(maximum, consecutive)
        previous = minute
    return {**tcp.minute_coverage([value['timestamp'] for value in selected], start, end, ATTEMPTS),
            'records': len(selected), 'attempts': len(measured), 'successes': successful,
            'failures': len(measured) - successful, 'monitor_errors': len(selected) - len(measured),
            'success_rate_percent': round(successful * 100 / len(measured), 3) if measured else None,
            'duration_ms': tcp.percentiles([value['total_ms'] for value in measured if value['success']]),
            'max_consecutive_failed_rounds': maximum, 'stages': stages,
            'investigate': maximum >= CONSECUTIVE_FAILURE_ROUNDS or
                           (stages['tcp']['duration_ms']['p95'] or 0) > TCP_P95_WARNING_MS}


def read_samples(directory, target, observer):
    if target not in TARGETS or observer not in tcp.OBSERVERS:
        raise ValueError('Unapproved summary labels')
    directory = Path(directory)
    tcp._no_link(directory)
    paths = sorted(directory.glob('https-????-??-??.jsonl'))
    if len(paths) > tcp.RETENTION_DAYS:
        raise ValueError('Too many logs')
    samples = []
    for path in paths:
        tcp._no_link(path)
        if path.stat().st_size > MAX_DAILY_LOG_BYTES:
            raise ValueError('Oversized log')
        with path.open(encoding='utf-8') as source:
            for index, line in enumerate(source):
                if index >= 18000 or len(line) > 2048:
                    raise ValueError('Oversized record stream')
                value = json.loads(line)
                if set(value) != FIELDS | {'schema', 'timestamp'} or value['schema'] != 1:
                    raise ValueError('Unexpected log schema')
                datetime.strptime(value['timestamp'], '%Y-%m-%dT%H:%M:%SZ')
                _validate_result({key: value[key] for key in FIELDS})
                if value['target'] == target and value['observer'] == observer:
                    samples.append(value)
                    if len(samples) > 7 * 24 * 60 * ATTEMPTS:
                        raise ValueError('Too many target samples')
    return samples


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--observer', required=True, choices=sorted(tcp.OBSERVERS))
    parser.add_argument('--state-dir', required=True, type=Path)
    parser.add_argument('--summary-start')
    parser.add_argument('--summary-end')
    args = parser.parse_args()
    try:
        if args.summary_start or args.summary_end:
            if not args.summary_start or not args.summary_end:
                raise ValueError('Both summary bounds required')
            report = {target: summarize_samples(read_samples(args.state_dir, target, args.observer),
                                                 args.summary_start, args.summary_end) for target in TARGETS}
        else:
            capped = False
            def save_result(result):
                nonlocal capped
                capped |= record(args.state_dir, result, datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))['log_capped']
            report = probe_window(args.observer, on_result=save_result)
            report['log_capped'] = capped
            window = {'schema': 1, 'observer': args.observer,
                      'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                      'window_budget_seconds': WINDOW_SECONDS,
                      'budget_skipped_attempts': report['budget_skipped_attempts'],
                      'attempts_by_target': {target: sum(value['target'] == target for value in report['attempts']) for target in TARGETS},
                      'monitor_errors': sum(value['monitor_error'] is not None for value in report['attempts']),
                      'log_capped': capped}
            tcp._save_state(args.state_dir / 'window.json', window)
        print(json.dumps({'schema': 1, 'observer': args.observer, **report}, separators=(',', ':'), allow_nan=False))
        return 1 if 'attempts' in report and any(value['monitor_error'] is not None for value in report['attempts']) else 0
    except (OSError, ValueError, KeyError, TypeError):
        print(json.dumps({'schema': 1, 'observer': args.observer, 'monitor_error': 'storage_or_measurement_failure'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
