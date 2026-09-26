import errno
import importlib.util
import json
from pathlib import Path
import socket
import sys

import pytest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/netmon_tcp_probe.py'


def load():
    assert SCRIPT.exists(), 'TCP443 probe implementation is missing'
    spec = importlib.util.spec_from_file_location('netmon_tcp_probe', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Connection:
    def __init__(self, failure=None):
        self.failure = failure
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.calls.append('closed')

    def settimeout(self, value):
        self.calls.append(('timeout', value))

    def connect(self, address):
        self.calls.append(('connect', address))
        if self.failure:
            raise self.failure


def measure(failure=None, elapsed_ns=123_456_789):
    module = load()
    connection = Connection(failure)
    ticks = iter([1_000_000, 1_000_000, 1_000_000 + elapsed_ns, 1_000_000 + elapsed_ns])
    result = module.connect_once(
        module.ORIGIN_IP, 'mainland_observer',
        socket_factory=lambda *_: connection, clock=lambda: next(ticks),
    )
    return module, connection, result


def test_success_records_actual_tcp_time_once_and_closes_socket():
    module, connection, result = measure()
    assert result['success'] is True
    assert result['tcp_connect_ms'] == 123.457
    assert result['attempt_elapsed_ms'] == 123.457
    assert result['error'] is None
    assert connection.calls == [('timeout', 3.0), ('connect', (module.ORIGIN_IP, 443)), 'closed']
    assert result['attempt_count'] == 1


@pytest.mark.parametrize('failure,error', [
    (socket.timeout('raw private URL?token=secret'), 'connect_timeout'),
    (ConnectionRefusedError(errno.ECONNREFUSED, 'private IP and identity'), 'connection_refused'),
    (OSError(errno.ENETUNREACH, 'raw address'), 'unreachable'),
    (PermissionError(errno.EACCES, 'private path'), 'permission_denied'),
    (OSError(errno.ECONNRESET, 'raw token secret'), 'socket_failure'),
    (OSError(10060, 'raw Windows timeout'), 'connect_timeout'),
    (OSError(10061, 'raw Windows refused'), 'connection_refused'),
    (OSError(10051, 'raw Windows route'), 'unreachable'),
    (OSError(10013, 'raw Windows permission'), 'permission_denied'),
])
def test_failure_uses_closed_category_real_elapsed_and_no_fabricated_tcp_time(failure, error):
    _, connection, result = measure(failure, elapsed_ns=11_000_000)
    assert result['success'] is False
    assert result['tcp_connect_ms'] is None
    assert result['attempt_elapsed_ms'] == 11.0
    assert result['error'] == error
    assert connection.calls[-1] == 'closed'
    payload = json.dumps(result)
    assert 'secret' not in payload and 'private' not in payload and 'token=' not in payload


def test_result_carries_only_infrastructure_labels_and_measured_tcp_fields():
    module, _, result = measure()
    payload = json.dumps(result)
    assert module.ORIGIN_IP not in payload
    assert result['target'] == 'origin_tcp443'
    assert result['observer'] == 'mainland_observer'
    assert 'dns_ms' not in result and 'tls_ms' not in result and 'ttfb_ms' not in result


def test_tcp_timing_excludes_socket_setup_and_cleanup():
    module = load()
    now = [0]
    class MeasuredConnection(Connection):
        def connect(self, address):
            super().connect(address)
            now[0] += 15_000_000
        def __exit__(self, *args):
            now[0] += 5_000_000
            super().__exit__(*args)
    def factory(*_):
        now[0] += 40_000_000
        return MeasuredConnection()
    result = module.connect_once(module.ORIGIN_IP, 'origin_server',
                                 socket_factory=factory, clock=lambda: now[0])
    assert result['tcp_connect_ms'] == 15.0
    assert result['attempt_elapsed_ms'] == 60.0


@pytest.mark.parametrize('origin,observer,timeout', [
    ('example.com', 'origin_server', 3),
    ('127.0.0.1', 'origin_server', 3),
    ('8.163.93.151', 'origin_server', 3),
    ('207.56.8.8', 'user@example.com', 3),
    ('207.56.8.8', 'origin_server', 0),
    ('207.56.8.8', 'origin_server', 31),
    ('207.56.8.8', 'origin_server', float('nan')),
])
def test_invalid_target_labels_and_unbounded_timeouts_rejected_before_network(origin, observer, timeout):
    module = load()
    with pytest.raises(ValueError):
        module.connect_once(origin, observer, timeout_seconds=timeout,
                            socket_factory=lambda *_: pytest.fail('network must not run'))


def test_summary_rate_uses_observed_attempts_and_bounded_history():
    module = load()
    summary = module.summarize([True, True, False])
    assert summary == {'attempts': 3, 'successes': 2, 'success_rate_percent': 66.667}
    assert module.summarize([])['success_rate_percent'] is None
    with pytest.raises(ValueError):
        module.summarize([True] * (module.WINDOW_ATTEMPTS + 1))


def test_one_minute_probe_window_has_three_bounded_real_attempts():
    module = load()
    failures = iter([None, ConnectionRefusedError(), None])
    ticks = iter([0, 0, 10_000_000, 10_000_000,
                  20_000_000, 20_000_000, 21_000_000, 21_000_000,
                  30_000_000, 30_000_000, 35_000_000, 35_000_000])
    results = module.probe_window(module.ORIGIN_IP, 'origin_server',
                                  socket_factory=lambda *_: Connection(next(failures)),
                                  clock=lambda: next(ticks))
    assert len(results) == 3
    assert [value['attempt_elapsed_ms'] for value in results] == [10.0, 1.0, 5.0]
    assert module.summarize([value['success'] for value in results])['success_rate_percent'] == 66.667


@pytest.mark.parametrize('count', [0, 4, 1000])
def test_probe_window_rejects_unbounded_attempt_counts(count):
    module = load()
    with pytest.raises(ValueError):
        module.probe_window(module.ORIGIN_IP, 'origin_server', attempts=count,
                            socket_factory=lambda *_: pytest.fail('network must not run'))


def test_history_is_bounded_and_roundtrip_has_no_arbitrary_fields(tmp_path):
    module, _, result = measure()
    for _ in range(100):
        report = module.record(tmp_path, result, '2026-09-26T00:00:00Z')
    assert report['window']['attempts'] == module.WINDOW_ATTEMPTS
    saved = json.loads((tmp_path / 'state.json').read_text())
    assert len(saved['history']) == module.WINDOW_ATTEMPTS
    assert set(saved) == {'schema', 'observer', 'history'}
    assert report['window']['success_rate_percent'] == 100.0
    assert report['state_reset'] is False


def test_corrupt_or_wrong_observer_state_is_not_used_for_rate(tmp_path):
    module, _, result = measure()
    state = tmp_path / 'state.json'
    for data in ['not JSON', json.dumps({'schema': 1, 'observer': 'origin_server', 'history': [False]})]:
        state.write_text(data)
        report = module.record(tmp_path, result, '2026-09-26T00:00:00Z')
        assert report['state_reset'] is True
        assert report['window']['attempts'] == 1


def test_log_retention_is_bounded_and_does_not_delete_unowned_files(tmp_path):
    module, _, result = measure()
    for day in range(1, 10):
        module.record(tmp_path, result, f'2026-09-{day:02d}T00:00:00Z')
    unrelated = tmp_path / 'customer.log'
    unrelated.write_text('untouched')
    module.record(tmp_path, result, '2026-09-10T00:00:00Z')
    assert len(list(tmp_path.glob('tcp-????-??-??.jsonl'))) <= module.RETENTION_DAYS
    assert unrelated.read_text() == 'untouched'


def test_daily_log_cap_does_not_prevent_recording_summary(tmp_path):
    module, _, result = measure()
    logfile = tmp_path / 'tcp-2026-09-26.jsonl'
    logfile.write_bytes(b'x' * module.MAX_DAILY_LOG_BYTES)
    report = module.record(tmp_path, result, '2026-09-26T00:00:00Z')
    assert report['log_capped'] is True
    assert logfile.stat().st_size == module.MAX_DAILY_LOG_BYTES
    assert report['window']['attempts'] == 1


def test_record_rejects_arbitrary_payload_before_writing(tmp_path):
    module, _, result = measure()
    result['token'] = 'must not be stored'
    with pytest.raises(ValueError):
        module.record(tmp_path, result, '2026-09-26T00:00:00Z')
    assert not list(tmp_path.iterdir())
