from datetime import datetime, timedelta, timezone
from importlib.util import find_spec
import pytest
from sqlalchemy import create_engine, select, func
from sqlalchemy.pool import StaticPool
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User, UserRole, Device, RefreshTokenFamily
from app.modules.identity.passwords import PasswordHasher


@pytest.fixture
def security():
    assert find_spec('app.modules.identity.operation_password') is not None, 'operation password service required'
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    engine=create_engine('sqlite://',connect_args={'check_same_thread':False},poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory=create_session_factory(engine)
    now=[datetime.now(timezone.utc)]
    hasher=PasswordHasher()
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',email='o@example.test',email_normalized='o@example.test',
            password_hash=hasher.hash('login-password-123'),status=AccountStatus.ACTIVE,created_at=now[0],updated_at=now[0]))
        session.add(UserRole(id='owner-role',user_id='owner',role_code='SUPER_ADMIN',assigned_by='fixture',assigned_at=now[0]))
        session.add(Device(id='device',user_id='owner',device_key='fixture',display_name='fixture',created_at=now[0],last_seen_at=now[0]))
        session.add(RefreshTokenFamily(id='family',user_id='owner',device_id='device',created_at=now[0]))
    claims=dict(sub='owner',device_id='device',family_id='family',iat=int(now[0].timestamp()),exp=int(now[0].timestamp())+3600)
    service=AdminWalletOperationPasswordService(factory,owner_id=lambda:'owner',auth_mode=lambda:'operation_password',clock=lambda:now[0])
    yield service,factory,now,claims
    engine.dispose()


def configure(security, **kwargs):
    return security[0].set_password(claims=security[3],login_password='login-password-123',
        new_operation_password='operation-password-123',idempotency_key='set',**kwargs)


def test_setup_replay_change_and_revoked_proof(security):
    service,factory,now,claims=security
    assert service.status(claims=claims)==dict(auth_mode='operation_password',configured=False,version=0)
    first=configure(security)
    assert first['version']==1 and configure(security)==first
    proof=service.verify(claims=claims,operation_password='operation-password-123')
    with factory.begin() as session: service.authorization(claims=claims,proof=proof)(session)()
    service.set_password(claims=claims,login_password='login-password-123',new_operation_password='replacement-password-123',
        current_operation_password='operation-password-123',idempotency_key='change')
    with factory.begin() as session:
        with pytest.raises(AppError,match='OPERATION_PASSWORD_CHANGED'):
            service.authorization(claims=claims,proof=proof)(session)
    assert service.status(claims=claims)['version']==2


def test_failed_attempts_survive_service_recreation_and_lock(security):
    service,factory,now,claims=security
    configure(security)
    for _ in range(5):
        with pytest.raises(AppError):service.verify(claims=claims,operation_password='incorrect-password')
    from app.modules.identity.operation_password import AdminWalletOperationPasswordService
    replacement=AdminWalletOperationPasswordService(factory,owner_id=lambda:'owner',auth_mode=lambda:'operation_password',clock=lambda:now[0])
    with pytest.raises(AppError,match='OPERATION_PASSWORD_RATE_LIMITED'):
        replacement.verify(claims=claims,operation_password='operation-password-123')
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.result=='FAILURE'))>=5


@pytest.mark.parametrize('new', ['short', 'x'*129, 'login-password-123'])
def test_invalid_or_login_equal_password_rejected(security,new):
    with pytest.raises(AppError):
        security[0].set_password(claims=security[3],login_password='login-password-123',new_operation_password=new,idempotency_key='set')
    assert not security[0].status(claims=security[3])['configured']


def test_change_requires_existing_password_and_no_secret_evidence(security):
    configure(security)
    with pytest.raises(AppError):
        security[0].set_password(claims=security[3],login_password='login-password-123',new_operation_password='replacement-password',idempotency_key='change')
    with security[1]() as session:
        evidence=str([r.after_data for r in session.scalars(select(AuditEvent))])+str([r.payload for r in session.scalars(select(OutboxEvent))])
        assert 'operation-password-123' not in evidence and 'login-password-123' not in evidence


def test_proof_age_and_session_revocation_are_rechecked(security):
    service,factory,now,claims=security
    configure(security)
    proof=service.verify(claims=claims,operation_password='operation-password-123')
    now[0]+=timedelta(seconds=31)
    with factory.begin() as session:
        with pytest.raises(AppError): service.authorization(claims=claims,proof=proof)(session)
    now[0]-=timedelta(seconds=31)
    with factory.begin() as session:session.get(RefreshTokenFamily,'family').revoked_at=now[0]
    with factory.begin() as session:
        with pytest.raises(AppError): service.authorization(claims=claims,proof=proof)(session)


def test_replay_and_success_do_not_reset_failed_guess_budget(security):
    configure(security)
    for _ in range(4):
        with pytest.raises(AppError):security[0].verify(claims=security[3],operation_password='incorrect-password')
        configure(security)
    with pytest.raises(AppError):security[0].verify(claims=security[3],operation_password='incorrect-password')
    with pytest.raises(AppError,match='OPERATION_PASSWORD_RATE_LIMITED'):
        configure(security)


@pytest.mark.parametrize('fault',['role','owner','old_login','hold'])
def test_actual_owner_role_recent_login_and_hold_required(security,fault):
    from app.modules.identity.models import SecurityHold
    from app.modules.identity.enums import HoldType
    service,factory,now,claims=security
    if fault=='owner':service.owner_id=lambda:'other'
    with factory.begin() as session:
        if fault=='role':session.delete(session.get(UserRole,'owner-role'))
        elif fault=='old_login':session.get(RefreshTokenFamily,'family').created_at=now[0]-timedelta(minutes=6)
        elif fault=='hold':session.add(SecurityHold(id='hold',user_id='owner',hold_type=HoldType.WITHDRAWAL,
            starts_at=now[0]-timedelta(seconds=1),ends_at=now[0]+timedelta(minutes=10),reason_code='RECOVERY',created_at=now[0]))
    with pytest.raises(AppError):configure(security)


def test_password_is_not_trimmed_and_changed_payload_conflicts(security):
    arguments=dict(claims=security[3],login_password='login-password-123',new_operation_password='  operation-password  ',idempotency_key='spaces')
    security[0].set_password(**arguments)
    with pytest.raises(AppError):security[0].verify(claims=security[3],operation_password='operation-password')
    assert security[0].verify(claims=security[3],operation_password=arguments['new_operation_password']).version==1
    with pytest.raises(AppError,match='OPERATION_PASSWORD_IDEMPOTENCY_CONFLICT'):
        security[0].set_password(**(arguments|{'new_operation_password':'other-password-123'}))


def test_commands_are_append_only_and_outbox_failure_rolls_back(security,monkeypatch):
    from sqlalchemy import update
    from app.modules.identity.operation_password_models import AdminOperationCommand
    configure(security)
    with security[1].begin() as session:
        with pytest.raises(ValueError,match='append-only'):
            session.execute(update(AdminOperationCommand).values(credential_version=999))
    def fail(*args,**kwargs):raise RuntimeError('synthetic outbox failure')
    from app.core.outbox import OutboxPublisher
    monkeypatch.setattr(OutboxPublisher,'enqueue',fail)
    with pytest.raises(RuntimeError):
        security[0].set_password(claims=security[3],login_password='login-password-123',
            current_operation_password='operation-password-123',new_operation_password='replacement-password',idempotency_key='change')
    assert security[0].status(claims=security[3])['version']==1
