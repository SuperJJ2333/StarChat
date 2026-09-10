from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, UserRole, Device, RefreshTokenFamily, AdminSession
from app.modules.identity.passwords import PasswordHasher


@pytest.fixture
def grant_context():
    from app.api.admin_wallet_auth import wallet_grant_service
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    engine = create_engine('sqlite://', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = [datetime.now(timezone.utc)]
    settings = SimpleNamespace(wallet_access_grant_enabled=True, wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_real_mode='manual_tron', wallet_access_policy_version='v1')
    with factory.begin() as session:
        session.add(User(id='owner', username='owner', username_normalized='owner', email='o@example.test',
            email_normalized='o@example.test', password_hash=PasswordHasher().hash('login-password-123'),
            status=AccountStatus.ACTIVE, created_at=now[0], updated_at=now[0]))
        session.add(UserRole(id='role', user_id='owner', role_code='SUPER_ADMIN', assigned_by='fixture', assigned_at=now[0]))
        session.add(Device(id='device', user_id='owner', device_key='fixture', display_name='fixture', created_at=now[0], last_seen_at=now[0]))
        session.add(RefreshTokenFamily(id='family', user_id='owner', device_id='device', created_at=now[0]))
        session.add(AdminSession(user_id='owner', family_id='family', authenticated_at=now[0],
            created_at=now[0], expires_at=now[0]+timedelta(hours=48)))
    claims = dict(sub='owner', device_id='device', family_id='family', session_scope='admin',
        iat=int(now[0].timestamp()), exp=int(now[0].timestamp())+172800)
    password = AdminWalletOperationPasswordService(factory, owner_id=lambda:'owner', auth_mode=lambda:'operation_password', clock=lambda:now[0])
    password.set_password(claims=claims, login_password='login-password-123', new_operation_password='operation-password-123', idempotency_key='setup')
    yield wallet_grant_service(settings, factory, lambda:now[0]), factory, now, claims, settings
    engine.dispose()


def issue(context):
    return context[0].verify(claims=context[3], operation_password='operation-password-123')


def test_fixed_deadline_and_old_login(grant_context):
    service, factory, now, claims, _ = grant_context
    now[0] += timedelta(minutes=10)
    first = issue(grant_context)
    assert first['verified'] and first['configured']
    for seconds in (301, 3599):
        now[0] = datetime.fromisoformat(first['verified_at']) + timedelta(seconds=seconds)
        assert service.status(claims=claims)['expires_at'] == first['expires_at']
        with factory.begin() as session: service.authorization(claims=claims)(session)()
    now[0] += timedelta(seconds=1)
    assert not service.status(claims=claims)['verified']
    with pytest.raises(AppError, match='WALLET_ACCESS_REQUIRED'): service.require(claims=claims)


@pytest.mark.parametrize('change', ['revoke', 'credential', 'role', 'family', 'device', 'policy', 'mode', 'owner', 'disabled'])
def test_live_invalidation(grant_context, change):
    service, factory, now, claims, settings = grant_context
    issue(grant_context)
    if change == 'revoke': service.revoke(claims=claims)
    elif change == 'policy': settings.wallet_access_policy_version = 'v2'
    elif change == 'mode': settings.wallet_admin_auth_mode = 'totp'
    elif change == 'owner': settings.wallet_manual_owner_admin_id = 'other'
    elif change == 'disabled': settings.wallet_access_grant_enabled = False
    else:
        with factory.begin() as session:
            if change == 'credential':
                from app.modules.identity.operation_password_models import AdminOperationCredential
                session.get(AdminOperationCredential, 'owner').version += 1
            elif change == 'role': session.delete(session.get(UserRole, 'role'))
            elif change == 'family': session.get(RefreshTokenFamily, 'family').revoked_at = now[0]
            elif change == 'device': session.get(Device, 'device').revoked_at = now[0]
    with pytest.raises(AppError): service.require(claims=claims)


def test_final_callback_rechecks_deadline_after_lock_wait(grant_context):
    service, factory, now, claims, _ = grant_context
    issue(grant_context)
    with factory.begin() as session:
        final = service.authorization(claims=claims)(session)
        now[0] += timedelta(hours=1)
        with pytest.raises(AppError, match='WALLET_ACCESS_REQUIRED'): final()


def test_admin_boundary_and_no_secret_persistence(grant_context):
    service, factory, now, claims, _ = grant_context
    issue(grant_context)
    from sqlalchemy import select
    from app.modules.audit.models import AuditEvent
    from app.core.outbox import OutboxEvent
    from app.modules.identity.wallet_grant_models import WalletAccessGrant
    with factory() as session:
        row = session.get(WalletAccessGrant, 'family')
        evidence = str(row.__dict__) + str([r.after_data for r in session.scalars(select(AuditEvent))])
        evidence += str([r.payload for r in session.scalars(select(OutboxEvent))])
        assert 'operation-password-123' not in evidence and 'login-password-123' not in evidence
    with pytest.raises(AppError): service.require(claims=claims | {'session_scope':'mobile'})
    with pytest.raises(AppError): service.require(claims=claims | {'family_id':'another'})
    with factory.begin() as session:
        session.get(AdminSession, 'owner').expires_at = now[0]
    with pytest.raises(AppError) as rejected: service.require(claims=claims)
    assert rejected.value.code == 'ACCESS_TOKEN_INVALID'


def test_verification_does_not_extend_existing_grant(grant_context):
    first = issue(grant_context)
    grant_context[2][0] += timedelta(minutes=30)
    assert issue(grant_context)['expires_at'] == first['expires_at']


def test_grant_deadline_stops_at_admin_absolute_deadline(grant_context):
    service, factory, now, claims, settings = grant_context
    deadline = now[0]+timedelta(minutes=12)
    with factory.begin() as session: session.get(AdminSession, 'owner').expires_at = deadline
    assert issue(grant_context)['expires_at'] == deadline.isoformat()


def test_totp_one_time_and_durable_attempts(grant_context):
    from app.modules.identity.totp import TotpService, FernetSecretProtector
    service, factory, now, claims, settings = grant_context
    settings.wallet_admin_auth_mode = 'totp'
    totp = TotpService(factory, protector=FernetSecretProtector.generate(), now_factory=lambda:now[0])
    enrollment = totp.enroll('owner')
    code = totp.code_at(enrollment.secret, now[0])
    totp.enable('owner', code)
    def verifier(**kwargs):
        totp.verify(kwargs['user_id'], kwargs['proof'])
        return True
    assert service.verify(claims=claims, mfa_proof=code, mfa_verifier=verifier)['verified']
    service.revoke(claims=claims)
    with pytest.raises(AppError) as replay:
        service.verify(claims=claims, mfa_proof=code, mfa_verifier=verifier)
    assert replay.value.code == 'TOTP_REPLAYED'
    for _ in range(3):
        with pytest.raises(AppError): service.verify(claims=claims, mfa_proof='000000', mfa_verifier=verifier)
    from app.api.admin_wallet_auth import wallet_grant_service
    recreated = wallet_grant_service(settings, factory, lambda:now[0])
    with pytest.raises(AppError) as limited:
        recreated.verify(claims=claims, mfa_proof='000000', mfa_verifier=verifier)
    assert limited.value.code == 'WALLET_ACCESS_RATE_LIMITED'


@pytest.mark.parametrize('previous_revoke', [False, True])
def test_revoke_during_verification_cannot_be_overwritten(grant_context, previous_revoke):
    from app.modules.identity.totp import TotpService, FernetSecretProtector
    service, factory, now, claims, settings = grant_context
    settings.wallet_admin_auth_mode = 'totp'
    totp = TotpService(factory, protector=FernetSecretProtector.generate(), now_factory=lambda:now[0])
    enrollment = totp.enroll('owner')
    totp.enable('owner', totp.code_at(enrollment.secret, now[0]))
    if previous_revoke:
        service.revoke(claims=claims)
    def verifier(**kwargs):
        service.revoke(claims=claims)
        return True
    with pytest.raises(AppError, match='WALLET_ACCESS_REQUIRED'):
        service.verify(claims=claims, mfa_proof='123456', mfa_verifier=verifier)
    assert not service.status(claims=claims)['verified']


def test_http_status_verify_revoke_no_store_and_refresh(grant_context):
    import jwt
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.api.wallet_access import create_wallet_access_router
    from app.core.errors import install_error_handlers
    service, factory, now, claims, settings = grant_context
    settings.jwt_secret = 'test-wallet-grant-jwt-secret-32-bytes-long'
    settings.jwt_issuer = 'wallet-test'
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_wallet_access_router(settings, factory, clock=lambda:now[0]), prefix='/api/v1')
    client = TestClient(app)
    def headers():
        return {'Authorization':'Bearer '+jwt.encode(claims | {'iss':settings.jwt_issuer,
            'iat':int(now[0].timestamp()), 'exp':int(now[0].timestamp())+900}, settings.jwt_secret, algorithm='HS256')}
    path = '/api/v1/wallet/manual/access'
    assert client.get(path).status_code == 401
    assert not client.get(path, headers=headers()).json()['verified']
    settings.wallet_access_grant_enabled = False
    settings.wallet_manual_owner_admin_id = 'another'
    from app.modules.identity.wallet_grant_models import WalletAccessGrant, WalletAccessAttempt
    WalletAccessGrant.__table__.drop(factory.kw['bind'])
    WalletAccessAttempt.__table__.drop(factory.kw['bind'])
    assert client.get(path, headers=headers()).json()['enabled'] is False
    settings.wallet_access_grant_enabled = True
    settings.wallet_manual_owner_admin_id = 'owner'
    WalletAccessGrant.__table__.create(factory.kw['bind'])
    WalletAccessAttempt.__table__.create(factory.kw['bind'])
    now[0] += timedelta(minutes=10)
    invalid = client.post(path+'/verify', headers=headers(), json={'operation_password':'wrong-operation-password'})
    assert invalid.status_code == 403
    verified = client.post(path+'/verify', headers=headers(), json={'operation_password':'operation-password-123'})
    assert verified.status_code == 200
    assert verified.headers['cache-control'] == 'no-store'
    deadline = verified.json()['expires_at']
    now[0] += timedelta(minutes=59)
    assert client.get(path, headers=headers()).json()['expires_at'] == deadline
    assert not client.post(path+'/revoke', headers=headers()).json()['verified']
    assert not client.get(path, headers=headers()).json()['verified']


def test_expanded_migration_stands_alone_and_preserves_rollback():
    from importlib.util import spec_from_file_location, module_from_spec
    from pathlib import Path
    from alembic.migration import MigrationContext
    from alembic.operations import Operations
    from sqlalchemy import inspect
    path = Path(__file__).resolve().parents[3] / 'services/business-api/migrations/versions/0062_wallet_access_grant.py'
    spec = spec_from_file_location('wallet_access_migration', path)
    migration = module_from_spec(spec)
    spec.loader.exec_module(migration)
    assert migration.down_revision == '0059_chat_payment_pin'
    engine = create_engine('sqlite://')
    with engine.begin() as connection:
        migration.op = Operations(MigrationContext.configure(connection))
        migration.upgrade()
        assert set(inspect(connection).get_table_names()) == {'identity_wallet_access_grants', 'identity_wallet_access_attempts'}
        with pytest.raises(RuntimeError, match='retain revocations'): migration.downgrade()
    engine.dispose()
