import httpx
from app.integrations.matrix_admin import SynapseMatrixAdminGateway


def test_worker_can_register_gateway_cleanup_without_missing_method():
    gateway = SynapseMatrixAdminGateway(homeserver_url='http://isolated.invalid',
        server_name='test', admin_access_token='test-only')
    from contextlib import ExitStack
    with ExitStack() as resources:
        resources.callback(gateway.close)
        assert not gateway._client.is_closed
    assert gateway._client.is_closed
    gateway.close()


def test_gateway_does_not_close_callers_injected_client():
    with httpx.Client() as client:
        gateway = SynapseMatrixAdminGateway(homeserver_url='http://isolated.invalid',
            server_name='test', admin_access_token='test-only', client=client)
        gateway.close()
        assert not client.is_closed
