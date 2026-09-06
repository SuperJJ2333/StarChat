import json

import httpx
import pytest

from app.core.errors import AppError
from app.integrations.matrix_admin import SynapseMatrixAdminGateway


def test_qr_invite_uses_moderator_client_membership_api_then_requester_join():
    requests = []

    def handle(request):
        requests.append(request)
        if request.url.path.endswith('/login'):
            return httpx.Response(200, json={'access_token': 'short-lived-test-token'})
        return httpx.Response(200, json={})

    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='matrix.test', admin_access_token='admin-test', client=httpx.Client(transport=httpx.MockTransport(handle)))
    gateway.invite_room_as_user('@moderator:matrix.test', '@user:matrix.test', '!room:matrix.test')
    gateway.join_room_as_user('@user:matrix.test', '!room:matrix.test', join_content={'com.changliao.join_source': 'qr'})
    assert requests[0].url.path == '/_synapse/admin/v1/users/@moderator:matrix.test/login'
    assert requests[1].url.path == '/_matrix/client/v3/rooms/!room:matrix.test/invite'
    assert json.loads(requests[1].content) == {'user_id': '@user:matrix.test'}
    assert requests[1].headers['Authorization'] == 'Bearer short-lived-test-token'
    assert requests[2].url.path == '/_synapse/admin/v1/users/@user:matrix.test/login'
    assert requests[3].url.path == '/_matrix/client/v3/join/!room:matrix.test'


@pytest.mark.parametrize('failure', ['denied', 'timeout', 'missing_token'])
def test_qr_invite_failure_is_redacted_and_stops(failure):
    requests = []

    def handle(request):
        requests.append(request)
        if failure == 'timeout':
            raise httpx.ReadTimeout('private response and credentials', request=request)
        if request.url.path.endswith('/login'):
            return httpx.Response(200, json={} if failure == 'missing_token' else {'access_token': 'test-token'})
        return httpx.Response(403, json={'error': 'private upstream details'})

    gateway = SynapseMatrixAdminGateway(homeserver_url='https://matrix.test', server_name='matrix.test', admin_access_token='admin-test', client=httpx.Client(transport=httpx.MockTransport(handle)))
    with pytest.raises(AppError) as error:
        gateway.invite_room_as_user('@moderator:matrix.test', '@user:matrix.test', '!room:matrix.test')
    assert error.value.code == 'MATRIX_GROUP_INVITE_FAILED'
    assert 'private' not in str(error.value)
    assert len(requests) == (2 if failure == 'denied' else 1)
