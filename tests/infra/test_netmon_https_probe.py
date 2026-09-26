import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/netmon_https_probe.py'


def load():
    assert SCRIPT.exists(), 'layered HTTPS probe missing'
    spec = importlib.util.spec_from_file_location('netmon_https_probe', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    sys.path.insert(0, str(SCRIPT.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def completed(code=0, values='200|0.004|0.024|0.074|0.104|0.105|0'):
    return subprocess.CompletedProcess([], code, stdout=values, stderr='private token')


def test_success_has_real_phase_differences_and_fixed_ip_has_no_dns_measurement():
    module = load()
    result = module.probe_once('business_dns', 'mainland_observer',
                              runner=lambda *a, **k: completed())
    assert result['dns_ms'] == 4.0 and result['tcp_connect_ms'] == 20.0
    assert result['tls_ms'] == 50.0 and result['ttfb_ms'] == 30.0
    assert result['total_ms'] == 105.0 and result['certificate_validated'] is True
    pinned = module.probe_once('business_ipv4_pinned', 'mainland_observer',
                               runner=lambda *a, **k: completed())
    assert pinned['dns_ms'] is None
    assert 'token' not in json.dumps(result)


@pytest.mark.parametrize('code,values,error,stage', [
    (6, '000|0|0|0|0|0.02|0', 'dns_failure', 'dns'),
    (28, '000|0.004|0|0|0|3.01|0', 'request_timeout', 'tcp'),
    (28, '000|0.004|0.024|0|0|3.01|0', 'request_timeout', 'tls'),
    (28, '000|0.004|0.024|0.074|0|6.01|0', 'request_timeout', 'response'),
    (60, '000|0.004|0.024|0|0|0.08|20', 'tls_failure', 'tls'),
])
def test_failed_later_stages_stay_null_without_fabricated_timing(code, values, error, stage):
    module = load()
    result = module.probe_once('business_dns', 'origin_server',
                              runner=lambda *a, **k: completed(code, values))
    assert result['success'] is False and result['error'] == error
    assert result['failure_stage'] == stage and result['ttfb_ms'] is None
    if stage == 'tcp':
        assert result['tcp_connect_ms'] is None and result['tls_ms'] is None
    assert result['http_status'] is None


def test_https_uses_certificate_verification_sni_fixed_origin_no_redirect_or_credentials():
    module = load()
    seen = []
    def run(command, **kwargs):
        seen.extend(command)
        return completed()
    module.probe_once('matrix_ipv4_pinned', 'origin_server', runner=run)
    assert '--resolve' in seen and 'liuhetong888.com:443:207.56.8.8' in seen
    assert '--connect-timeout' in seen and '--max-time' in seen
    assert '--noproxy' in seen and '*' in seen
    assert '-k' not in seen and '--insecure' not in seen and '-L' not in seen
    assert not any('Authorization' in value for value in seen)
    assert seen[1] == '--disable'  # Ignore global curlrc credentials/insecure defaults.


def test_unapproved_target_is_rejected_without_network():
    module = load()
    with pytest.raises(ValueError):
        module.probe_once('https://private/?token=x', 'origin_server',
                          runner=lambda *a, **k: pytest.fail('no network'))


def test_invalid_curl_output_is_monitor_error_not_network_failure():
    module = load()
    result = module.probe_once('business_dns', 'origin_server',
                              runner=lambda *a, **k: completed(0, 'private token'))
    assert result['monitor_error'] == 'invalid_measurement'
    assert result['error'] is None and result['success'] is None
    assert 'private' not in json.dumps(result)


def test_three_attempts_each_target_fit_hard_window_budget_and_skips_are_not_failures():
    module = load()
    now = [0.0]
    def run(command, **kwargs):
        now[0] += 6.0
        return completed(28, '000|0.004|0|0|0|6|0')
    result = module.probe_window('origin_server', runner=run, clock=lambda: now[0])
    assert now[0] <= 30.0
    assert len(result['attempts']) == 5
    assert result['budget_skipped_attempts'] == 7
    assert result['window_budget_seconds'] == 30


def test_rollup_separates_missing_minutes_monitor_errors_and_network_failures():
    module = load()
    good = module.probe_once('business_dns', 'origin_server', runner=lambda *a, **k: completed())
    fail = module.probe_once('business_dns', 'origin_server', runner=lambda *a, **k: completed(28, '000|0.004|0|0|0|3|0'))
    report = module.summarize_samples([
        {'timestamp': '2026-09-26T00:00:00Z', **good},
        {'timestamp': '2026-09-26T00:02:00Z', **fail}],
        '2026-09-26T00:00:00Z', '2026-09-26T00:02:59Z')
    assert report['missing_minutes'] == 1 and report['attempts'] == 2
    assert report['successes'] == 1 and report['failures'] == 1
    assert report['stages']['tcp']['successes'] == 1
    assert report['stages']['tls']['attempts'] == 1
    assert report['stages']['tcp']['duration_ms']['p95'] == 20.0


def test_retention_cap_and_closed_fields_are_enforced(tmp_path):
    module = load()
    good = module.probe_once('business_dns', 'origin_server', runner=lambda *a, **k: completed())
    with pytest.raises(ValueError):
        module.record(tmp_path, {**good, 'token': 'not allowed'}, '2026-09-26T00:00:00Z')
    assert not list(tmp_path.iterdir())
    for day in range(1, 10):
        module.record(tmp_path, good, f'2026-09-{day:02d}T00:00:00Z')
    assert len(list(tmp_path.glob('https-*.jsonl'))) == 7
    path = tmp_path / 'https-2026-09-26.jsonl'
    path.write_bytes(b'x' * module.MAX_DAILY_LOG_BYTES)
    assert module.record(tmp_path, good, '2026-09-26T00:00:00Z')['log_capped'] is True
    assert path.stat().st_size == module.MAX_DAILY_LOG_BYTES


def test_monitor_deadline_and_unavailable_are_independent_of_service_failure():
    module = load()
    for exception, expected in [(FileNotFoundError('private path'), 'process_unavailable'),
                                 (subprocess.TimeoutExpired('private command', 6), 'process_deadline')]:
        def run(*args, **kwargs):
            raise exception
        result = module.probe_once('business_dns', 'origin_server', runner=run)
        assert result['monitor_error'] == expected and result['success'] is None
        assert result['total_ms'] is None and result['error'] is None


def test_three_consecutive_failed_rounds_ignore_gap_and_threshold_is_diagnostic():
    module = load()
    failed = module.probe_once('business_dns', 'origin_server', runner=lambda *a, **k: completed(28, '000|0.004|0|0|0|3|0'))
    rows = [{'timestamp': f'2026-09-26T00:0{minute}:0{attempt}Z', **failed}
            for minute in (0, 1, 2, 4) for attempt in range(3)]
    result = module.summarize_samples(rows, '2026-09-26T00:00:00Z', '2026-09-26T00:04:59Z')
    assert result['max_consecutive_failed_rounds'] == 3
    assert result['investigate'] is True and result['missing_minutes'] == 1


def test_record_rejects_inconsistent_or_non_boolean_certificate(tmp_path):
    module = load()
    good = module.probe_once('business_dns', 'origin_server', runner=lambda *a, **k: completed())
    for forged in ({**good, 'certificate_validated': 1}, {**good, 'tls_ms': None},
                   {**good, 'error': 'request_timeout'}, {**good, 'failure_stage': 'tcp'}):
        with pytest.raises(ValueError):
            module.record(tmp_path, forged, '2026-09-26T00:00:00Z')


def test_timeout_without_completed_stage_is_unknown_not_assumed_dns_failure():
    module = load()
    result = module.probe_once('business_dns', 'origin_server',
                              runner=lambda *a, **k: completed(28, '000|0|0|0|0|3|0'))
    assert result['failure_stage'] == 'unknown'
    assert result['dns_ms'] is None and result['tcp_connect_ms'] is None


def test_http_401_is_completed_transport_and_business_rejection():
    module = load()
    result = module.probe_once('business_dns', 'origin_server',
                              runner=lambda *a, **k: completed(0, '401|0.004|0.024|0.074|0.104|0.105|0'))
    assert result['error'] == 'auth_failure' and result['certificate_validated'] is True
    assert result['http_status'] == 401 and result['ttfb_ms'] == 30.0


def test_summary_reader_streams_one_target_and_rejects_foreign_payload(tmp_path):
    module = load()
    for target in ('business_dns', 'matrix_dns'):
        result = module.probe_once(target, 'origin_server', runner=lambda *a, **k: completed())
        module.record(tmp_path, result, '2026-09-26T00:00:00Z')
    assert len(module.read_samples(tmp_path, 'business_dns', 'origin_server')) == 1
    path = tmp_path / 'https-2026-09-26.jsonl'
    with path.open('a') as output:
        output.write(json.dumps({'token': 'must not return'}) + '\n')
    with pytest.raises(ValueError):
        module.read_samples(tmp_path, 'business_dns', 'origin_server')


def test_cli_monitor_failure_exits_one_but_records_closed_failure(tmp_path, monkeypatch, capsys):
    module = load()
    result = {**module._empty('business_dns', 'origin_server'), 'monitor_error': 'process_unavailable'}
    def probe(observer, on_result):
        on_result(result)
        return {'window_budget_seconds': 30, 'attempts': [result], 'budget_skipped_attempts': 11}
    monkeypatch.setattr(module, 'probe_window', probe)
    monkeypatch.setattr(sys, 'argv', ['probe', '--observer', 'origin_server', '--state-dir', str(tmp_path)])
    assert module.main() == 1
    report = json.loads(capsys.readouterr().out)
    assert report['attempts'][0]['success'] is None
    window = json.loads((tmp_path / 'window.json').read_text())
    assert window['budget_skipped_attempts'] == 11 and window['monitor_errors'] == 1
