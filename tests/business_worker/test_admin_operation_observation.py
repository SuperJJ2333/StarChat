from dataclasses import replace
from datetime import datetime,timedelta,timezone
from types import SimpleNamespace
import pytest
from sqlalchemy import create_engine,select,func
from app.core.database import Base,create_session_factory
from app.core.outbox import OutboxConsumer,OutboxEvent,OutboxPublisher,OutboxMessage
from app.modules.audit.models import AuditEvent
from app.modules.identity.models import User,UserRole,Device,RefreshTokenFamily
from app.modules.identity.enums import AccountStatus
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.operation_password import AdminWalletOperationPasswordService
from app.modules.identity.operation_password_models import AdminOperationCredential
from app.modules.wallet import funding_models, binding_models
from main import build_identity_handlers
from worker import Worker


def handlers(factory):
    def forbidden(*args,**kwargs):raise AssertionError('network side effect forbidden')
    return build_identity_handlers(session_factory=factory,verification_secret='synthetic-secret',
        public_base_url='https://example.test',email_sender=SimpleNamespace(send_verification=forbidden))


def test_real_setup_and_verification_events_are_observed_without_side_effects():
    engine=create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory=create_session_factory(engine)
    now=datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',email='owner@example.test',email_normalized='owner@example.test',
            password_hash=PasswordHasher().hash('synthetic-login-password'),status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
        session.add(UserRole(id='role',user_id='owner',role_code='SUPER_ADMIN',assigned_by='fixture',assigned_at=now))
        session.add(Device(id='device',user_id='owner',device_key='fixture',display_name='fixture',created_at=now,last_seen_at=now))
        session.add(RefreshTokenFamily(id='family',user_id='owner',device_id='device',created_at=now))
    claims=dict(sub='owner',device_id='device',family_id='family',iat=int(now.timestamp()),exp=int(now.timestamp())+3600)
    service=AdminWalletOperationPasswordService(factory,owner_id=lambda:'owner',auth_mode=lambda:'operation_password',clock=lambda:now)
    service.set_password(claims=claims,login_password='synthetic-login-password',new_operation_password='synthetic-operation-password',idempotency_key='setup')
    service.verify(claims=claims,operation_password='synthetic-operation-password')
    with factory.begin() as session:
        unknown=OutboxPublisher.enqueue(session,topic='unrelated.unknown',event_type='unknown',aggregate_type='test',aggregate_id='test',payload={},now=now-timedelta(hours=1))
        before_audits=session.scalar(select(func.count()).select_from(AuditEvent))
    worker=Worker(consumer=OutboxConsumer(factory,now_factory=lambda:now),handlers=handlers(factory),worker_id='test',now_factory=lambda:now)
    worker.run_once(limit=20)
    with factory() as session:
        events=list(session.scalars(select(OutboxEvent).where(OutboxEvent.event_type.in_(
            ('identity.admin_operation.changed','identity.admin_operation.verified')))))
        assert len(events)==2 and all(event.status=='PUBLISHED' for event in events)
        assert all(event.topic=='identity.admin_operation' for event in events)
        assert session.get(OutboxEvent,unknown).status=='DEAD'
        assert session.get(AdminOperationCredential,'owner').version==1
        assert session.scalar(select(func.count()).select_from(AuditEvent))==before_audits
    worker.run_once(limit=20)
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent))==before_audits
    engine.dispose()


@pytest.mark.parametrize('field,value',[
    ('topic','identity'),('event_type','identity.admin_operation.deleted'),('aggregate_type','user'),
    ('aggregate_id',''),('payload',{'version':True,'auth_mode':'operation_password'}),
    ('payload',{'version':0,'auth_mode':'operation_password'}),
    ('payload',{'version':1,'auth_mode':'totp'}),
    ('payload',{'version':1,'auth_mode':'operation_password','password':'synthetic-sensitive'}),
])
def test_observer_rejects_invalid_contract(field,value):
    from tasks.admin_operation_observation import AdminOperationObservationTask
    message=OutboxMessage(id='event',topic='identity.admin_operation',event_type='identity.admin_operation.changed',
        aggregate_type='admin_operation_credential',aggregate_id='owner',payload={'version':1,'auth_mode':'operation_password'},headers={},attempt_count=0)
    with pytest.raises(ValueError,match='ADMIN_OPERATION_EVENT_INVALID') as failure:
        AdminOperationObservationTask()(replace(message,**{field:value}))
    assert 'synthetic-sensitive' not in str(failure.value)


def test_malformed_scoped_event_is_failed_by_actual_worker_not_published():
    engine=create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory=create_session_factory(engine)
    now=datetime.now(timezone.utc)
    with factory.begin() as session:
        identifier=OutboxPublisher.enqueue(session,topic='identity.admin_operation',event_type='identity.admin_operation.changed',
            aggregate_type='admin_operation_credential',aggregate_id='owner',payload={'version':1,'auth_mode':'operation_password','secret':'synthetic-sensitive'},now=now)
    worker=Worker(consumer=OutboxConsumer(factory,now_factory=lambda:now),handlers=handlers(factory),worker_id='test',now_factory=lambda:now)
    worker.run_once(limit=10)
    with factory() as session:
        event=session.get(OutboxEvent,identifier)
        assert event.status=='FAILED'
        assert event.last_error=='ADMIN_OPERATION_EVENT_INVALID'
        assert event.published_at is None
    engine.dispose()
