import httpx
import pytest

from app.core.errors import AppError
from app.integrations.matrix_admin import SynapseMatrixAdminGateway


def gateway(handler):
    return SynapseMatrixAdminGateway(homeserver_url='https://matrix.example.invalid',
        server_name='matrix.example.invalid', admin_access_token='test-admin-token',
        client=httpx.Client(transport=httpx.MockTransport(handler)))


def test_gateway_device_operations_use_only_verified_user_path():
    seen = []
    def handler(request):
        seen.append((request.method, request.url.raw_path.decode()))
        if request.url.path.endswith('/whoami'):
            assert request.headers['Authorization'] == 'Bearer memory-token'
            return httpx.Response(200, json={'user_id': '@alice:example.invalid', 'device_id': 'PHONE'})
        assert request.headers['Authorization'] == 'Bearer test-admin-token'
        if request.method == 'GET':
            return httpx.Response(200, json={'devices': [{'device_id': 'PHONE'}, {'device_id': 'OLD'}]})
        return httpx.Response(200, json={})
    adapter = gateway(handler)
    assert adapter.session_identity('memory-token') == ('@alice:example.invalid', 'PHONE')
    assert adapter.list_devices('@alice:example.invalid') == ['OLD', 'PHONE']
    adapter.revoke_device('@alice:example.invalid', 'OLD')
    assert seen[-1] == ('DELETE', '/_synapse/admin/v2/users/%40alice%3Aexample.invalid/devices/OLD')


@pytest.mark.parametrize('body', [{'user_id': '@alice:test'},
    {'user_id': '@alice:test', 'device_id': 'PHONE', 'is_guest': True}, []])
def test_gateway_rejects_incomplete_whoami(body):
    adapter = gateway(lambda _: httpx.Response(200, json=body))
    with pytest.raises(AppError) as error:
        adapter.session_identity('memory-token')
    assert error.value.code == 'MATRIX_SESSION_IDENTITY_INVALID'
    assert 'memory-token' not in str(error.value)


def test_gateway_network_failure_is_retryable_and_has_no_token():
    def fail(request):
        raise httpx.ConnectError('memory-token', request=request)
    adapter = gateway(fail)
    with pytest.raises(AppError) as error:
        adapter.session_identity('memory-token')
    assert error.value.status_code == 503
    assert 'memory-token' not in str(error.value)


def test_gateway_missing_device_delete_is_idempotent():
    gateway(lambda _: httpx.Response(404, json={})).revoke_device('@alice:test', 'OLD')
