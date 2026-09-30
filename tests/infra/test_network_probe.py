import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def module():
    path = ROOT / 'scripts/network_probe.py'
    assert path.is_file(), 'HTTPS network probe is not implemented'
    spec = importlib.util.spec_from_file_location('network_probe_tested', path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


@pytest.mark.parametrize('url', [
    'http://example.com/', 'https://user:password@example.com/',
    'https://example.com/?token=secret', 'https://example.com/#secret',
    'https://example.com:0/', 'https://example.com/\n--insecure',
])
def test_unsafe_target_rejected(url):
    with pytest.raises(ValueError):
        module().validate_url(url)


def test_output_requires_task_artifacts_and_resolves_symlinks(tmp_path):
    tool = module()
    with pytest.raises(ValueError):
        tool.validate_output(ROOT / 'report.jsonl')
    expected = ROOT / 'docs/verification/artifacts/2026-09-26/probe-test/result.jsonl'
    assert tool.validate_output(expected) == expected.resolve()


def test_curl_enforces_tls_no_redirect_no_implicit_proxy(tmp_path):
    command = module().curl_command('curl', 'https://example.com/health', tmp_path / 'body',
                                    timeout=5, address='203.0.113.8')
    assert command[1] == '--disable'
    assert '--insecure' not in command and '-k' not in command
    assert '--location' not in command and '-L' not in command
    assert command[command.index('--noproxy') + 1] == '*'
    assert command[command.index('--proxy') + 1] == ''
    assert command[command.index('--resolve') + 1] == 'example.com:443:203.0.113.8'
    assert '--retry' in command and '--max-filesize' in command


def test_phases_and_fixed_ip_dns_bypass_are_explicit():
    payload = {'http_code': 200, 'remote_ip': '203.0.113.8', 'time_namelookup': .01,
               'time_connect': .04, 'time_appconnect': .09, 'time_starttransfer': .13,
               'time_total': .15}
    tool = module()
    row = tool.measurement(payload, 0, address_override=False)
    assert row['dns_ms'] == pytest.approx(10)
    assert row['tcp_ms'] == pytest.approx(30)
    assert row['tls_ms'] == pytest.approx(50)
    assert row['ttfb_ms'] == pytest.approx(130)
    assert row['total_ms'] == pytest.approx(150)
    assert tool.measurement(payload, 0, address_override=True)['dns_ms'] is None


def test_failed_connect_retained_without_fake_tls_or_raw_error():
    row = module().measurement({'http_code': 0, 'time_namelookup': .01,
                                'time_connect': 0, 'time_appconnect': 0,
                                'time_total': 5}, 28, address_override=False)
    assert row['success'] is False and row['error'] == 'timeout'
    assert row['tcp_ms'] is None and row['tls_ms'] is None
    assert row['total_ms'] == 5000


def test_html_200_is_not_json_health_success(tmp_path):
    tool = module()

    def fake_run(command, **kwargs):
        Path(command[command.index('--output') + 1]).write_text('<html>ok</html>', encoding='utf-8')
        return subprocess.CompletedProcess(command, 0,
            stdout=json.dumps({'http_code': 200, 'time_total': .1}), stderr='private-token')

    row = tool.probe_once('https://example.com/health', workdir=tmp_path,
                          timeout=5, expect_json=('status', 'ready'), runner=fake_run)
    assert row['success'] is False and row['error'] == 'health_mismatch'
    assert 'private-token' not in json.dumps(row)
    assert list(tmp_path.iterdir()) == []
