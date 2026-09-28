"""Business username changes preserve immutable user and Matrix identities."""
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from sqlalchemy import create_engine, func, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.idempotency import IdempotencyRecord
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.invitations import InvitationService
from app.modules.identity.models import User
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService


@pytest.fixture(scope='session')
def valid_password_hash():
    return PasswordHasher().hash('correct horse battery staple')


@pytest.fixture
def username_components(valid_password_hash):
    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False, 'autocommit': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    settings = Settings(_env_file=None, environment='test',
        database_url='sqlite+pysqlite:///:memory:', redis_url='redis://unused',
        jwt_secret='test-jwt-secret-at-least-thirty-two-bytes',
        email_verification_secret='test-email-verification-secret',
        password_reset_secret='test-password-reset-secret')
    with factory.begin() as session:
        for user_id, name in [('alice', 'AliceOriginal'), ('bob', 'BobOriginal')]:
            session.add(User(id=user_id, username=name, username_normalized=name.casefold(),
                email=f'{user_id}@example.test', email_normalized=f'{user_id}@example.test',
                phone='+8613800000001' if user_id == 'alice' else None,
                phone_normalized='+8613800000001' if user_id == 'alice' else None,
                phone_verified_at=now if user_id == 'alice' else None,
                password_hash=valid_password_hash,
                status=AccountStatus.ACTIVE, matrix_user_id=f'@{name.casefold()}:matrix.example.test',
                email_verified_at=now, nickname=user_id, signature='unchanged',
                created_at=now, updated_at=now, profile_updated_at=now))
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    auth = {user_id: {'Authorization': 'Bearer ' + tokens.issue_pair(user_id=user_id,
        device_key=f'device-{user_id}', display_name='username test').access_token}
        for user_id in ['alice', 'bob']}
    app = create_app(settings, session_factory=factory)
    yield factory, app, auth, now
    engine.dispose()


@pytest.mark.asyncio
async def test_change_routes_are_authenticated_and_profile_masks_phone(username_components):
    _, app, auth, _ = username_components
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        for method, url, kwargs in [
            ('get', '/api/v1/profile/username-change', {}),
            ('get', '/api/v1/profile/username-availability?username=NewAlice', {}),
            ('patch', '/api/v1/profile/username', {'json': {'username': 'NewAlice'}, 'headers': {'Idempotency-Key': 'change'}}),
        ]:
            assert (await client.request(method, url, **kwargs)).status_code == 401
        profile = await client.get('/api/v1/profile/me', headers=auth['alice'])
        assert profile.json()['masked_phone'] == '+86****0001'
        policy = await client.get('/api/v1/profile/username-change', headers=auth['alice'])
        assert policy.status_code == 200
        assert policy.json() == {'username': 'AliceOriginal', 'can_change': True,
            'next_change_at': None, 'min_length': 6, 'max_length': 20}
        assert policy.headers['cache-control'] == 'no-store'


@pytest.mark.asyncio
async def test_rename_atomic_receipt_idempotency_and_stable_identity(username_components):
    factory, app, auth, _ = username_components
    headers = {**auth['alice'], 'Idempotency-Key': 'rename-alice'}
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        first = await client.patch('/api/v1/profile/username', headers=headers, json={'username': 'AliceNew'})
        assert first.status_code == 200
        assert first.json()['username'] == 'AliceNew' and first.json()['changed'] is True
        replay = await client.patch('/api/v1/profile/username', headers=headers, json={'username': 'AliceNew'})
        assert replay.json() == first.json()
        mismatch = await client.patch('/api/v1/profile/username', headers=headers, json={'username': 'AliceNext'})
        assert mismatch.status_code == 409 and mismatch.json()['error']['code'] == 'IDEMPOTENCY_KEY_REUSED'
        cooldown = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'new-key'}, json={'username': 'AliceNext'})
        assert cooldown.status_code == 409 and cooldown.json()['error']['code'] == 'USERNAME_CHANGE_COOLDOWN'
        profile = await client.get('/api/v1/profile/me', headers=auth['alice'])
        assert profile.json()['username'] == 'AliceNew'
        policy = await client.get('/api/v1/profile/username-change', headers=auth['alice'])
        assert policy.json()['can_change'] is False and policy.json()['next_change_at'] == first.json()['next_change_at']
    with factory() as session:
        user = session.get(User, 'alice')
        assert user.username_normalized == 'alicenew'
        assert user.matrix_user_id == '@aliceoriginal:matrix.example.test'
        assert user.nickname == 'alice' and user.signature == 'unchanged'
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.action == 'identity.username.changed')) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.event_type == 'identity.profile.changed')) == 1
        records = list(session.scalars(select(IdempotencyRecord).where(IdempotencyRecord.scope == 'identity.username.change:alice')))
        assert len(records) == 1 and records[0].response_body == first.json()


@pytest.mark.asyncio
@pytest.mark.parametrize('name', ['abcde', 'a' * 21, '1alice', 'alice.name', '中文abcdef', 'alice name', 'alice@name'])
async def test_rename_format_is_ascii_six_to_twenty(username_components, name):
    _, app, auth, _ = username_components
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        availability = await client.get('/api/v1/profile/username-availability', headers=auth['alice'], params={'username': name})
        renamed = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'format'}, json={'username': name})
        assert availability.status_code == renamed.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize('name', ['a23456', 'A' + '9' * 19])
async def test_rename_length_boundaries_are_accepted(username_components, name):
    _, app, auth, _ = username_components
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        available = await client.get('/api/v1/profile/username-availability', headers=auth['alice'], params={'username': name})
        assert available.status_code == 200 and available.json()['available'] is True
        renamed = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'boundary'}, json={'username': name})
        assert renamed.status_code == 200 and renamed.json()['username'] == name


@pytest.mark.asyncio
async def test_casefold_noop_and_reserved_old_name(username_components):
    factory, app, auth, _ = username_components
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        noop = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'noop'}, json={'username': 'ALICEORIGINAL'})
        assert noop.status_code == 200 and noop.json() == {'username': 'AliceOriginal', 'changed': False, 'next_change_at': None}
        taken = await client.get('/api/v1/profile/username-availability', headers=auth['bob'], params={'username': 'aliceoriginal'})
        assert taken.status_code == 200 and taken.json()['available'] is False
        renamed = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'real-change'}, json={'username': 'Alice-New_01'})
        assert renamed.status_code == 200
        taken = await client.patch('/api/v1/profile/username', headers={**auth['bob'], 'Idempotency-Key': 'old-name'}, json={'username': 'ALICEORIGINAL'})
        assert taken.status_code == 409 and taken.json()['error']['code'] == 'USERNAME_TAKEN'
    with factory() as session:
        from app.modules.identity.models import UsernameClaim
        claims = list(session.scalars(select(UsernameClaim).where(UsernameClaim.owner_user_id == 'alice')))
        assert {item.normalized for item in claims} == {'aliceoriginal', 'alice-new_01'}


def test_utc_365_day_boundary_and_owned_previous_name(username_components):
    from app.modules.identity.username import UsernameService
    factory, _, _, now = username_components
    clock = [now]
    service = UsernameService(factory, now_factory=lambda: clock[0])
    first = service.change('alice', 'AliceFirst', idempotency_key='first', trace_id='test', source_ip=None)
    clock[0] = now + timedelta(days=365) - timedelta(microseconds=1)
    assert service.policy('alice')['can_change'] is False
    clock[0] += timedelta(microseconds=1)
    assert service.policy('alice')['can_change'] is True
    second = service.change('alice', 'AliceOriginal', idempotency_key='second', trace_id='test', source_ip=None)
    assert second['changed'] is True
    # Historical replay is the original immutable receipt, even after another rename.
    assert service.change('alice', 'AliceFirst', idempotency_key='first', trace_id='test', source_ip=None) == first


def test_phone_auto_handle_checks_historical_claims(username_components):
    from app.modules.identity.registration import RegistrationService, VerificationTokenCodec
    from app.modules.identity.models import UsernameClaim
    factory, _, _, now = username_components
    codec = VerificationTokenCodec(b'test-email-verification-secret')
    phone = '+8613900000001'
    historical = 'p' + codec.digest(purpose='phone-public-handle', value=phone)[:24]
    with factory.begin() as session:
        session.add(UsernameClaim(normalized=historical, owner_user_id='alice', created_at=now))
    invitations = InvitationService(factory, now_factory=lambda: now)
    invitations.issue(code='PHONE-RENAME', max_uses=1, expires_at=now + timedelta(days=1), created_by='admin')
    service = RegistrationService(factory, invitation_service=invitations,
        password_hasher=PasswordHasher(), token_codec=codec, now_factory=lambda: now)
    with factory.begin() as session:
        user = service.create_verified_phone_in_session(session, phone=phone, invitation_code='PHONE-RENAME', now=now)
        assert user.username.startswith(historical) and user.username != historical
        assert len(user.username) > 20  # Existing generated handles remain compatible.
        owner = session.scalar(select(UsernameClaim.owner_user_id).where(UsernameClaim.normalized == user.username_normalized))
        assert owner == user.id


def test_unavailable_rename_rolls_back_claim_and_idempotency(username_components):
    from app.modules.identity.username import UsernameService
    from app.modules.identity.models import UsernameClaim
    from app.core.errors import AppError
    factory, _, _, _ = username_components
    service = UsernameService(factory)
    with pytest.raises(AppError) as caught:
        service.change('alice', 'BobOriginal', idempotency_key='failed', trace_id='test', source_ip=None)
    assert caught.value.code == 'USERNAME_TAKEN'
    with factory() as session:
        assert session.get(User, 'alice').username == 'AliceOriginal'
        assert session.scalar(select(func.count()).select_from(UsernameClaim)) == 0
        assert session.scalar(select(func.count()).select_from(IdempotencyRecord).where(IdempotencyRecord.scope == 'identity.username.change:alice')) == 0


@pytest.mark.asyncio
async def test_availability_limits_and_strict_request(username_components):
    from app.core.errors import AppError
    factory, app, auth, _ = username_components
    class RecordingLimiter:
        def __init__(self):
            self.calls = []
        def hit(self, key, *, limit, window_seconds):
            self.calls.append((key, limit, window_seconds))
            raise AppError(code='RATE_LIMITED', message='请求过于频繁', status_code=429)
    limiter = RecordingLimiter()
    # Use the public router factory to isolate its injected limiter.
    from app.api.profile import create_profile_router
    from fastapi import FastAPI
    from app.core.errors import install_error_handlers
    limited_app = FastAPI()
    install_error_handlers(limited_app)
    settings = Settings(_env_file=None, environment='test', jwt_secret='test-jwt-secret-at-least-thirty-two-bytes')
    limited_app.include_router(create_profile_router(settings, factory, storage=None, rate_limiter=limiter), prefix='/api/v1')
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=limited_app), base_url='http://test') as client:
        response = await client.get('/api/v1/profile/username-availability?username=NewAlice', headers=auth['alice'])
        assert response.status_code == 429
        assert limiter.calls == [('identity:username:availability:alice', 60, 60)]
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        bad = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'strict'},
            json={'username': 'AliceNew', 'matrix_user_id': '@attacker:matrix.test'})
        assert bad.status_code == 422
        blank_key = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': ' '},
            json={'username': 'AliceNew'})
        assert blank_key.status_code == 422 and blank_key.json()['error']['code'] == 'IDEMPOTENCY_REQUIRED'


@pytest.mark.asyncio
async def test_new_name_login_and_search_old_name_registration_denied(username_components):
    factory, app, auth, now = username_components
    InvitationService(factory, now_factory=lambda: now).issue(code='RENAME-INVITE', max_uses=2,
        expires_at=now + timedelta(days=1), created_by='admin')
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        response = await client.patch('/api/v1/profile/username', headers={**auth['alice'], 'Idempotency-Key': 'rename'}, json={'username': 'AliceNew'})
        assert response.status_code == 200
        login = await client.post('/api/v1/auth/login', json={'username': 'alicenew', 'password': 'correct horse battery staple', 'device_key': 'new-device', 'device_name': 'New'})
        assert login.status_code == 200
        assert login.json()['matrix_user_id'] == '@aliceoriginal:matrix.example.test'
        old_login = await client.post('/api/v1/auth/login', json={'username': 'aliceoriginal', 'password': 'correct horse battery staple', 'device_key': 'old-device', 'device_name': 'Old'})
        assert old_login.status_code == 401
        old_register = await client.post('/api/v1/auth/register', headers={'Idempotency-Key': 'register-old'}, json={'username': 'ALICEORIGINAL', 'email': 'fresh@example.test', 'password': 'correct horse battery staple', 'invitation_code': 'RENAME-INVITE'})
        assert old_register.status_code == 409
    from app.modules.identity.profile import ProfileService
    # Search uses business usernames; it does not infer Matrix localparts.
    service = ProfileService(factory, storage=None)
    assert [row.user_id for row in service.search_public_profiles('alicenew', exclude_user_ids=set())] == ['alice']
    assert service.search_public_profiles('aliceoriginal', exclude_user_ids=set()) == []
