import pytest
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.identity.matrix_login import MatrixLoginTokenService
from test_mobile_sessions import mobile_sessions


class Gateway:
    def __init__(self):
        self.calls = []
        self.fail = False

    def complete_mobile_login(self, *, matrix_user_id, device_id, generation, display_name):
        self.calls.append((matrix_user_id, device_id, generation))
        if self.fail:
            raise AppError(code='MATRIX_LOGIN_PENDING', message='retry', status_code=503)
        return {'user_id': matrix_user_id, 'device_id': device_id, 'access_token': 'memory-only'}


def setup(mobile_sessions):
    factory, tokens = mobile_sessions
    gateway = Gateway()
    service = MatrixLoginTokenService(factory, gateway=gateway,
        public_homeserver_url='https://matrix.example', expires_in=60)
    pair = tokens.issue_pair(user_id='alice', device_key='phone', display_name='phone')
    return factory, tokens, gateway, service, pair


def test_opaque_grant_is_one_time_and_not_native(mobile_sessions):
    factory, _, gateway, service, pair = setup(mobile_sessions)
    grant = service.issue('alice', family_id=pair.family_id)
    assert len(grant.login_token) >= 40
    response = service.consume({'type': 'm.login.token', 'token': grant.login_token, 'device_id': 'D'})
    assert response['access_token'] == 'memory-only'
    assert gateway.calls == [('@alice:matrix.localhost', 'D', 1)]
    with pytest.raises(AppError):
        service.consume({'type': 'm.login.token', 'token': grant.login_token})
    from app.modules.identity.models import MatrixLoginGrant
    with factory() as session:
        row = session.scalar(select(MatrixLoginGrant))
        assert row.token_hash != grant.login_token
        assert row.consumed_at is not None


def test_replaced_grant_and_raw_native_token_never_reach_synapse(mobile_sessions):
    _, tokens, gateway, service, pair = setup(mobile_sessions)
    grant = service.issue('alice', family_id=pair.family_id)
    tokens.issue_pair(user_id='alice', device_key='other', display_name='other')
    for token in [grant.login_token, 'native-synapse-token']:
        with pytest.raises(AppError):
            service.consume({'type': 'm.login.token', 'token': token})
    assert gateway.calls == []


def test_unknown_result_burns_grant_and_next_attempt_has_higher_generation(mobile_sessions):
    _, _, gateway, service, pair = setup(mobile_sessions)
    grant = service.issue('alice', family_id=pair.family_id)
    gateway.fail = True
    with pytest.raises(AppError):
        service.consume({'type': 'm.login.token', 'token': grant.login_token})
    gateway.fail = False
    grant = service.issue('alice', family_id=pair.family_id)
    service.consume({'type': 'm.login.token', 'token': grant.login_token})
    assert [call[2] for call in gateway.calls] == [1, 2]


def test_new_family_cannot_complete_by_binding_an_old_matrix_token(mobile_sessions):
    from app.modules.identity.matrix_sessions import MatrixSessionService
    factory, _, gateway, _, pair = setup(mobile_sessions)
    with pytest.raises(AppError) as failure:
        MatrixSessionService(factory, gateway=gateway).bind(user_id='alice', family_id=pair.family_id,
            matrix_access_token='old', matrix_device_id='D')
    assert failure.value.code == 'MATRIX_LOGIN_REQUIRED'


@pytest.mark.asyncio
async def test_broker_public_matrix_shape_and_no_secret_errors(caplog):
    import httpx
    from test_matrix_login_token import _components, _add_user, _access_token
    gateway = Gateway()
    engine, factory, app, _ = _components(gateway)
    _add_user(factory, 'alice', mxid='@alice:matrix.example.test')
    access = _access_token(factory, 'alice')
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        path = '/api/v1/auth/matrix-broker'
        assert (await client.get(path)).json() == {'flows': [{'type': 'm.login.token'}]}
        grant = (await client.post('/api/v1/auth/matrix-login-token', headers={'Authorization': f'Bearer {access}'})).json()['login_token']
        response = await client.post(path, json={'type': 'm.login.token', 'token': grant, 'device_id': 'D'})
        assert response.status_code == 200
        assert response.json()['device_id'] == 'D'
        assert response.headers['cache-control'] == 'no-store'
        rejected = await client.post(path, json={'type': 'm.login.password', 'password': 'do-not-log'})
        assert rejected.status_code == 403
        assert rejected.json()['errcode'] == 'M_FORBIDDEN'
        assert 'do-not-log' not in rejected.text + caplog.text
        assert grant not in caplog.text
    engine.dispose()


def test_gateway_internal_login_is_sanitized_and_uses_private_resource():
    import httpx
    from app.integrations.matrix_admin import SynapseMatrixAdminGateway
    def handler(request):
        assert request.url.path == '/_synapse/client/chatflow/mobile_login'
        assert request.headers['Authorization'] == 'Bearer admin-secret'
        return httpx.Response(500, json={'error': 'upstream-secret'})
    gateway = SynapseMatrixAdminGateway(homeserver_url='http://private', server_name='matrix.localhost',
        admin_access_token='admin-secret', client=httpx.Client(transport=httpx.MockTransport(handler)))
    with pytest.raises(AppError) as failure:
        gateway.complete_mobile_login(matrix_user_id='@alice:matrix.localhost', device_id='D', generation=1, display_name=None)
    assert failure.value.status_code == 503
    assert 'secret' not in str(failure.value)


@pytest.mark.parametrize('device_id', ['', False, 0, [], {}])
def test_explicit_invalid_device_is_rejected(mobile_sessions, device_id):
    _, _, gateway, service, pair = setup(mobile_sessions)
    grant = service.issue('alice', family_id=pair.family_id)
    with pytest.raises(AppError):
        service.consume({'type':'m.login.token','token':grant.login_token,'device_id':device_id})
    assert gateway.calls == []


def test_matrix_token_expiry_survives_broker_response(mobile_sessions):
    _, _, gateway, service, pair = setup(mobile_sessions)
    original = gateway.complete_mobile_login
    gateway.complete_mobile_login = lambda **kwargs: {**original(**kwargs), 'expires_in_ms': 90000}
    grant = service.issue('alice', family_id=pair.family_id)
    assert service.consume({'type':'m.login.token','token':grant.login_token})['expires_in_ms'] == 90000


def test_expired_grant_cannot_reach_synapse(mobile_sessions):
    from datetime import datetime, timedelta, timezone
    from app.modules.identity.models import MatrixLoginGrant
    factory, _, gateway, service, pair = setup(mobile_sessions)
    grant = service.issue('alice', family_id=pair.family_id)
    with factory.begin() as session:
        session.scalar(select(MatrixLoginGrant)).expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    with pytest.raises(AppError):
        service.consume({'type':'m.login.token','token':grant.login_token})
    assert gateway.calls == []


def test_completion_and_retired_outbox_never_issue_unfenced_native_deletes(mobile_sessions):
    from types import SimpleNamespace
    from app.modules.identity.matrix_sessions import MatrixSessionService
    factory, _, gateway, broker, pair = setup(mobile_sessions)
    grant = broker.issue('alice', family_id=pair.family_id)
    broker.consume({'type':'m.login.token','token':grant.login_token,'device_id':'D'})
    gateway.session_identity = lambda token: ('@alice:matrix.localhost', 'D')
    gateway.list_devices = lambda _: pytest.fail('completion must not enumerate/delete devices')
    gateway.revoke_device = lambda *_: pytest.fail('unfenced native delete forbidden')
    service = MatrixSessionService(factory, gateway=gateway)
    assert service.bind(user_id='alice', family_id=pair.family_id, matrix_access_token='memory-only', matrix_device_id='D') == {'status':'ACTIVE'}
    service.revoke_from_outbox(SimpleNamespace(payload={'user_id':'alice','matrix_device_id':'OLD'},
        event_type='identity.matrix.device.revoke.requested',aggregate_type='user',aggregate_id='alice'))
    with pytest.raises(AppError):
        service.revoke_from_outbox(SimpleNamespace(payload={'user_id':'alice','matrix_device_id':'OLD'},
            event_type='identity.matrix.device.revoke.requested',aggregate_type='user',aggregate_id='wrong-user'))
