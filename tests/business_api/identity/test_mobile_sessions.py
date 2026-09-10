from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import AdminSession, RefreshTokenFamily, User, UserRole
from app.modules.identity.tokens import TokenService
from app.modules.identity.matrix_sessions import MatrixSessionService


@pytest.fixture
def mobile_sessions():
    engine = create_engine('sqlite+pysqlite:///:memory:')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='alice', username='alice', username_normalized='alice',
            email='alice@example.invalid', email_normalized='alice@example.invalid',
            password_hash='unused', status=AccountStatus.ACTIVE,
            matrix_user_id='@alice:matrix.localhost', created_at=now, updated_at=now))
        session.add(UserRole(id='role', user_id='alice', role_code=RoleCode.SUPER_ADMIN,
            assigned_by='alice', assigned_at=now))
    tokens = TokenService(factory, jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer='liuhetong')
    yield factory, tokens
    engine.dispose()


@pytest.mark.parametrize('new_device', ['android', 'ios'])
def test_new_mobile_login_replaces_old_access_and_refresh(mobile_sessions, new_device):
    factory, tokens = mobile_sessions
    old = tokens.issue_pair(user_id='alice', device_key='ios', display_name='iPhone')
    current = tokens.issue_pair(user_id='alice', device_key=new_device, display_name='Phone')
    for action in [lambda: tokens.decode_access_token(old.access_token),
                   lambda: tokens.rotate(old.refresh_token)]:
        with pytest.raises(AppError) as failure:
            action()
        assert failure.value.code == 'SESSION_REPLACED'
    assert tokens.decode_access_token(current.access_token)['family_id'] == current.family_id
    assert [device.id for device in tokens.list_devices('alice')] == [current.device_id]
    with factory() as session:
        active = list(session.scalars(select(RefreshTokenFamily).where(
            RefreshTokenFamily.revoked_at.is_(None))))
        assert [family.id for family in active] == [current.family_id]


def test_mobile_replacement_does_not_revoke_admin(mobile_sessions):
    factory, tokens = mobile_sessions
    admin = tokens.issue_admin_pair(user_id='alice', display_name='Browser')
    tokens.issue_pair(user_id='alice', device_key='ios', display_name='iPhone')
    latest = tokens.issue_pair(user_id='alice', device_key='android', display_name='Android')
    assert tokens.decode_access_token(admin.access_token)['family_id'] == admin.family_id
    assert tokens.decode_access_token(latest.access_token)['family_id'] == latest.family_id
    with factory() as session:
        assert session.get(AdminSession, 'alice').family_id == admin.family_id


class MatrixGateway:
    def __init__(self):
        self.devices = {'OLD', 'CURRENT'}
        self.fail_revoke = False
        self.deleted = []

    def session_identity(self, token):
        assert token == 'memory-only-matrix-token'
        return '@alice:matrix.localhost', 'CURRENT'

    def list_devices(self, user_id):
        assert user_id == '@alice:matrix.localhost'
        return sorted(self.devices)

    def revoke_device(self, user_id, device_id):
        assert user_id == '@alice:matrix.localhost'
        if self.fail_revoke:
            raise AppError(code='MATRIX_DEVICE_REVOKE_FAILED', message='upstream unavailable', status_code=503)
        self.deleted.append(device_id)
        self.devices.discard(device_id)


def bind_service(mobile_sessions):
    factory, tokens = mobile_sessions
    gateway = MatrixGateway()
    pair = tokens.issue_pair(user_id='alice', device_key='android', display_name='Android')
    from app.modules.identity.models import MobileMatrixSession
    with factory.begin() as session:
        session.add(MobileMatrixSession(user_id='alice', family_id=pair.family_id,
            matrix_device_id='CURRENT', updated_at=datetime.now(timezone.utc)))
    service = MatrixSessionService(factory, gateway=gateway)
    return factory, tokens, pair, gateway, service


def test_binding_only_verifies_broker_identity_without_native_revoke(mobile_sessions):
    _, _, pair, gateway, service = bind_service(mobile_sessions)
    result = service.bind(user_id='alice', family_id=pair.family_id,
        matrix_access_token='memory-only-matrix-token', matrix_device_id='CURRENT')
    assert result == {'status': 'ACTIVE'}
    assert gateway.deleted == []
    assert gateway.devices == {'OLD', 'CURRENT'}


def test_wrong_matrix_device_cannot_revoke_any_device(mobile_sessions):
    _, _, pair, gateway, service = bind_service(mobile_sessions)
    with pytest.raises(AppError) as error:
        service.bind(user_id='alice', family_id=pair.family_id,
            matrix_access_token='memory-only-matrix-token', matrix_device_id='FORGED')
    assert error.value.code == 'MATRIX_LOGIN_REQUIRED'
    assert gateway.deleted == []


def test_completion_does_not_enqueue_unfenced_revoke(mobile_sessions):
    from app.core.outbox import OutboxEvent
    factory, _, pair, gateway, service = bind_service(mobile_sessions)
    gateway.fail_revoke = True
    assert service.bind(user_id='alice', family_id=pair.family_id,
        matrix_access_token='memory-only-matrix-token', matrix_device_id='CURRENT') == {'status': 'ACTIVE'}
    with factory() as session:
        assert list(session.scalars(select(OutboxEvent))) == []


def test_replaced_family_cannot_bind_or_revoke(mobile_sessions):
    _, tokens, pair, gateway, service = bind_service(mobile_sessions)
    tokens.issue_pair(user_id='alice', device_key='ios', display_name='iOS')
    with pytest.raises(AppError) as error:
        service.bind(user_id='alice', family_id=pair.family_id,
            matrix_access_token='memory-only-matrix-token', matrix_device_id='CURRENT')
    assert error.value.code == 'SESSION_REPLACED'
    assert gateway.deleted == []


def test_delayed_revoke_does_not_delete_reactivated_device(mobile_sessions):
    from app.core.outbox import OutboxMessage
    _, _, pair, gateway, service = bind_service(mobile_sessions)
    service.bind(user_id='alice', family_id=pair.family_id,
        matrix_access_token='memory-only-matrix-token', matrix_device_id='CURRENT')
    message = OutboxMessage(id='event', topic='identity.matrix_session',
        event_type='identity.matrix.device.revoke.requested', aggregate_type='user',
        aggregate_id='alice', payload={'user_id': 'alice', 'matrix_device_id': 'CURRENT'},
        headers={}, attempt_count=2)
    service.revoke_from_outbox(message)
    assert gateway.deleted == []


@pytest.mark.parametrize('identity', [('@other:matrix.localhost', 'CURRENT'),
                                    ('@alice:matrix.localhost', '')])
def test_wrong_user_or_missing_device_is_rejected(mobile_sessions, identity):
    _, _, pair, gateway, service = bind_service(mobile_sessions)
    gateway.session_identity = lambda _: identity
    with pytest.raises(AppError) as error:
        service.bind(user_id='alice', family_id=pair.family_id,
            matrix_access_token='memory-only-matrix-token', matrix_device_id='CURRENT')
    assert error.value.code == 'MATRIX_SESSION_IDENTITY_MISMATCH'
    assert gateway.deleted == []
