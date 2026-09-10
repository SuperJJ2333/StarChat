import importlib.util
from pathlib import Path

import httpx
import pytest


def load_cli():
    path = Path(__file__).resolve().parents[2] / 'scripts/admin_deposit_repair.py'
    spec = importlib.util.spec_from_file_location('repair_cli', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def invoke(args, monkeypatch, responses=None):
    cli = load_cli()
    monkeypatch.setenv('STARCHAT_ADMIN_TOKEN', 'test-secret-token')
    requests = []
    def handle(request):
        requests.append(request)
        if isinstance(responses, Exception):
            raise responses
        return httpx.Response(200, json=responses or {'items': []})
    def factory(**kwargs):
        assert kwargs['verify'] is True
        assert kwargs['follow_redirects'] is False
        assert kwargs['trust_env'] is False
        return httpx.Client(transport=httpx.MockTransport(handle), **kwargs)
    result = cli.main(['--base-url', 'https://admin.example.test', *args], client_factory=factory)
    return result, requests


def test_default_does_not_request(monkeypatch):
    result, requests = invoke([], monkeypatch)
    assert result == 0 and not requests


def test_candidates_exact_path_auth_and_redacted_output(monkeypatch, capsys):
    result, requests = invoke(['candidates', '--txid', 'a'*64, '--log-index', '2'], monkeypatch,
        {'source_address': 'T'+'A'*33, 'message': 'test-secret-token'})
    assert result == 0 and len(requests) == 1
    assert requests[0].url.path == '/api/v1/admin/wallet/manual/deposit-repairs/candidates'
    assert requests[0].url.params['log_index'] == '2'
    assert requests[0].headers['Authorization'] == 'Bearer test-secret-token'
    output = capsys.readouterr().out
    assert 'T'+'A'*33 not in output and 'test-secret-token' not in output


def test_preview_explicit_attestation(monkeypatch):
    import json
    result, requests = invoke(['preview', '--receipt-id', 'receipt', '--intent-id', 'intent',
        '--reason-code', 'PAYMENT_BEFORE_ORDER', '--reason-detail', '人工核对依据', '--payment-attestation'], monkeypatch)
    assert result == 0 and requests[0].url.path.endswith('/preview')
    assert json.loads(requests[0].content)['payment_attestation'] is True


def execute_args():
    return ['execute', '--preview-id', 'preview', '--digest', 'b'*64, '--expected-version', '1', '--operation-id', 'stable-operation']


def test_execute_requires_confirmation(monkeypatch):
    with pytest.raises(SystemExit):
        invoke(execute_args(), monkeypatch)


def test_execute_stable_id_and_no_retry_on_unknown(monkeypatch, capsys):
    result, requests = invoke([*execute_args(), '--confirm'], monkeypatch, httpx.ReadTimeout('secret transport detail'))
    assert result == 3 and len(requests) == 1
    assert requests[0].headers['Idempotency-Key'] == 'stable-operation'
    output = capsys.readouterr().out
    assert 'stable-operation' in output and 'UNKNOWN_RESULT' in output
    assert 'secret transport detail' not in output


def test_status_is_get_only(monkeypatch):
    result, requests = invoke(['status', '--operation-id', 'stable-operation'], monkeypatch)
    assert result == 0 and requests[0].method == 'GET'
    assert requests[0].url.path.endswith('/stable-operation')


def test_execute_success_sends_exact_command(monkeypatch):
    import json
    result, requests = invoke([*execute_args(), '--confirm'], monkeypatch, {'status': 'EXECUTED'})
    assert result == 0 and len(requests) == 1
    assert json.loads(requests[0].content) == {'preview_id': 'preview', 'digest': 'b'*64,
        'expected_version': 1, 'operation_id': 'stable-operation', 'confirmed': True}


def test_redirect_does_not_forward_credentials(monkeypatch):
    cli = load_cli()
    monkeypatch.setenv('STARCHAT_ADMIN_TOKEN', 'test-token')
    requests = []
    def handle(request):
        requests.append(request)
        return httpx.Response(307, headers={'Location': 'https://other.example.test/collect'})
    def factory(**kwargs):
        return httpx.Client(transport=httpx.MockTransport(handle), **kwargs)
    assert cli.main(['--base-url', 'https://admin.example.test', 'status', '--operation-id', 'test'],
        client_factory=factory) == 2
    assert len(requests) == 1


def test_refuses_http_or_url_credentials(monkeypatch):
    cli = load_cli()
    monkeypatch.setenv('STARCHAT_ADMIN_TOKEN', 'test-token')
    for base in ['http://admin.example.test', 'https://user:pass@admin.example.test']:
        assert cli.main(['--base-url', base, 'status', '--operation-id', 'test']) == 2
