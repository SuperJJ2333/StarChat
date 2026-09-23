from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
import os

import pytest
from sqlalchemy import create_engine, select, func
from test_deposit_receipts import core  # noqa: F401
from test_support_order_settlement_integration import prepared_order
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.models import LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeRequest
from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation


def prepare(core):
    service, order_id, token = prepared_order(core)
    prepared = service.prepare_settlement(request_id=order_id, actor_id='cs', claim_token=token,
        final_rate='7.123456', idempotency_key='prepare')
    return service, order_id, token, prepared


def execute(service, order_id, token, key='execute', **kwargs):
    return service.execute_settlement(request_id=order_id, actor_id='cs', claim_token=token,
        idempotency_key=key, authorization=kwargs.get('authorization', lambda session: lambda: None))


def test_verified_staff_credits_without_approval_and_never_fakes_review(core):
    service, order_id, token, prepared = prepare(core)
    result = execute(service, order_id, token)
    assert result['status'] == 'CREDITED'
    assert prepared['settlement_approval_required'] is False
    assert Decimal(prepared['binding_final_rate']) == Decimal('7.123456')
    assert Decimal(prepared['binding_final_caibi_amount']) == Decimal('71.23')
    for key in ('execute', 'new-key'):
        assert execute(service, order_id, token, key)['status'] == 'CREDITED'
    assert service.ledger.balance('alice') == Decimal('71.23')
    with core[1]() as session:
        adjustment = session.get(AdjustmentRequest, prepared['adjustment_id'])
        assert adjustment.status == 'EXECUTED'
        assert adjustment.finance_reviewer_id is None and adjustment.admin_reviewer_id is None
        assert session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == 'recharge.direct_settlement_executed')) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == 'recharge.direct_settlement_executed')) is not None
        assert session.scalar(select(RechargeReceiptReservation)).state == 'CONSUMED'


@pytest.mark.parametrize('change', ['authorization', 'claim', 'payment', 'rejected'])
def test_direct_execution_preserves_financial_guards(core, change):
    service, order_id, token, prepared = prepare(core)
    if change in ('payment', 'rejected'):
        with core[1].begin() as session:
            if change == 'payment': session.get(RechargeRequest, order_id).payment_verified_at = None
            else: session.get(AdjustmentRequest, prepared['adjustment_id']).status = 'REJECTED'
    with pytest.raises(AppError):
        execute(service, order_id, 'wrong' if change == 'claim' else token,
            authorization=None if change == 'authorization' else lambda session: lambda: None)
    assert service.ledger.balance('alice') == 0


def test_scoped_public_interface_cannot_execute_generic_unapproved_adjustment(core):
    service, _, token, prepared = prepare(core)
    with core[1].begin() as session:
        session.get(AdjustmentRequest, prepared['adjustment_id']).idempotency_key = 'generic-adjustment'
    workflow = AdjustmentWorkflow(core[1], service.ledger, admin_threshold=Decimal('1000'))
    with pytest.raises(AppError):
        workflow.execute_support_recharge(prepared['adjustment_id'], actor_id='cs',
            idempotency_key='invalid-scope', support_claim_token=token,
            support_authorization=lambda session: lambda: None)
    assert service.ledger.balance('alice') == 0


def test_direct_execution_final_auth_failure_rolls_back_every_financial_write(core):
    service, order_id, token, prepared = prepare(core)
    def authorization(session):
        def fresh():
            if session.get(AdjustmentRequest, prepared['adjustment_id']).status == 'EXECUTED':
                raise AppError(code='PERMISSION_DENIED', message='revoked', status_code=403)
        return fresh
    with pytest.raises(AppError): execute(service, order_id, token, authorization=authorization)
    assert service.ledger.balance('alice') == 0
    with core[1]() as session:
        assert session.get(AdjustmentRequest, prepared['adjustment_id']).status == 'SUBMITTED'
        assert session.scalar(select(RechargeReceiptReservation)).state == 'RESERVED'


def test_old_approved_execution_recovers_registration_without_second_credit(core, monkeypatch):
    service, order_id, token, prepared = prepare(core)
    workflow = AdjustmentWorkflow(core[1], service.ledger, admin_threshold=Decimal('1000'))
    workflow.finance_review(prepared['adjustment_id'], reviewer_id='finance', approve=True)
    workflow.execute(prepared['adjustment_id'], actor_id='cs', idempotency_key='old-route',
        support_claim_token=token, support_authorization=lambda session: lambda: None)
    assert execute(service, order_id, token)['status'] == 'CREDITED'
    assert service.ledger.balance('alice') == Decimal('71.23')
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1


def test_concurrent_direct_requests_share_single_ledger_credit(tmp_path, monkeypatch):
    import test_deposit_receipts as fixture_module
    engine = create_engine('sqlite:///' + str(tmp_path/'direct.db'),
        connect_args={'check_same_thread': False, 'timeout': 30})
    monkeypatch.setattr(fixture_module, 'create_engine', lambda *args, **kwargs: engine)
    generator = fixture_module.core.__wrapped__()
    core = next(generator)
    try:
        service, order_id, token, _ = prepare(core)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda key: execute(service, order_id, token, key), ('one', 'two')))
        assert all(result['status'] == 'CREDITED' for result in results)
        assert service.ledger.balance('alice') == Decimal('71.23')
        with core[1]() as session:
            assert session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1
    finally:
        generator.close()

def test_generic_submit_cannot_forge_support_recharge_namespace(core):
    workflow = AdjustmentWorkflow(core[1], LedgerService(core[1]),
        admin_threshold=Decimal('1000'))
    workflow.set_policy('cs', per_transaction=Decimal('100'), per_day=Decimal('1000'), allowed_users={'alice'})
    with pytest.raises(ValueError, match='reserved'):
        workflow.submit(actor_id='cs', user_id='alice', amount=Decimal('70'),
            reason_code='RECHARGE_CREDIT', idempotency_key='support-recharge:forged')
    with core[1]() as session:
        assert session.scalar(select(AdjustmentRequest)) is None

@pytest.mark.skipif(not os.getenv('SUPPORT_ORDER_POSTGRES_URL'), reason='isolated PostgreSQL URL required')
def test_postgres_direct_recharge_concurrency_and_commit_revocation(monkeypatch):
    import os
    from pathlib import Path
    from uuid import uuid4
    from sqlalchemy import text
    from sqlalchemy.engine import make_url
    from sqlalchemy.orm import Session, sessionmaker
    from alembic import command
    from alembic.config import Config
    import test_deposit_receipts as fixture_module
    from app.modules.wallet.models import WalletControl
    from app.modules.ledger.reserve import RedeemabilityReserve

    url = make_url(os.environ['SUPPORT_ORDER_POSTGRES_URL'])
    schema = 'direct_' + uuid4().hex
    bootstrap = create_engine(url, isolation_level='AUTOCOMMIT')
    with bootstrap.connect() as connection:
        connection.execute(text('CREATE SCHEMA ' + schema))
    bootstrap.dispose()
    scoped_url = url.update_query_dict({'options': '-csearch_path=' + schema})
    monkeypatch.setenv('BUSINESS_DATABASE_URL', scoped_url.render_as_string(hide_password=False))
    config = Config('services/business-api/alembic.ini')
    config.set_main_option('path_separator', 'os')
    config.set_main_option('script_location', str(Path('services/business-api/migrations').resolve()))
    command.upgrade(config, 'head')
    engine = create_engine(scoped_url)
    monkeypatch.setattr(fixture_module, 'create_engine', lambda *args, **kwargs: engine)
    class SeedSession(Session):
        def add(self, instance, *, _warn=True):
            if isinstance(instance, (WalletControl, RedeemabilityReserve)):
                existing = self.get(type(instance), instance.id)
                if existing is not None:
                    for name, value in vars(instance).items():
                        if not name.startswith('_'): setattr(existing, name, value)
                    return
            super().add(instance, _warn=_warn)
    monkeypatch.setattr(fixture_module, 'create_session_factory', lambda engine:
        sessionmaker(engine, class_=SeedSession, expire_on_commit=False))
    generator = fixture_module.core.__wrapped__()
    core = next(generator)
    try:
        test_direct_execution_final_auth_failure_rolls_back_every_financial_write(core)
        service, order_id, token, prepared = prepare(core)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda key: execute(service, order_id, token, key), ('pg-one', 'pg-two')))
        assert all(result['status'] == 'CREDITED' for result in results)
        assert service.ledger.balance('alice') == Decimal('71.23')
        with core[1]() as session:
            assert session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1
            assert session.get(AdjustmentRequest, prepared['adjustment_id']).finance_reviewer_id is None
            assert session.scalar(select(RechargeReceiptReservation)).state == 'CONSUMED'
    finally:
        generator.close()

def test_direct_credit_registration_crash_recovers_through_worker_without_reviewer(core, monkeypatch):
    from app.modules.recharge.service import RechargeService
    service, order_id, token, prepared = prepare(core)
    def lost_response(**kwargs):
        raise RuntimeError('crash after direct financial commit')
    monkeypatch.setattr(service, 'complete_bound', lost_response)
    with pytest.raises(RuntimeError, match='crash after direct financial commit'):
        execute(service, order_id, token)
    worker = RechargeService(core[1], ledger=service.ledger)
    assert worker.sweep_pending_registrations()['completed'] == 1
    assert worker.sweep_pending_registrations()['scanned'] == 0
    assert service.ledger.balance('alice') == Decimal('71.23')
    with core[1]() as session:
        adjustment = session.get(AdjustmentRequest, prepared['adjustment_id'])
        assert adjustment.finance_reviewer_id is None and adjustment.admin_reviewer_id is None
        assert session.get(RechargeRequest, order_id).status == 'CREDITED'
        assert session.scalar(select(func.count()).select_from(LedgerTransaction)) == 1

def test_real_http_staff_session_direct_settlement_preserves_response_fields_and_permissions(tmp_path, monkeypatch):
    from datetime import datetime, timezone
    from fastapi import FastAPI
    import asyncio
    from httpx import ASGITransport, AsyncClient
    from app.api.recharge import create_recharge_router
    from app.core.config import Settings
    from app.core.errors import install_error_handlers
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import User, UserRole
    from app.modules.identity.passwords import PasswordHasher
    from app.modules.identity.phone import PhoneOtpService, RecordingSmsSender
    from app.modules.identity.staff_activation import StaffActivationService
    from app.modules.identity.tokens import TokenService
    import test_deposit_receipts as fixture_module
    engine = create_engine('sqlite:///' + str(tmp_path/'http-direct.db'),
        connect_args={'check_same_thread': False, 'timeout': 30})
    monkeypatch.setattr(fixture_module, 'create_engine', lambda *args, **kwargs: engine)
    generator = fixture_module.core.__wrapped__()
    core = next(generator)
    try:
        now = datetime.now(timezone.utc)
        password = 'fixture-staff-password-123'
        with core[1].begin() as session:
            session.add(User(id='cs', username='cs', username_normalized='cs',
                email='cs@example.test', email_normalized='cs@example.test', email_verified_at=now,
                password_hash=PasswordHasher().hash(password), status='ACTIVE', created_at=now, updated_at=now))
            session.flush()
            session.add(UserRole(id='cs-role', user_id='cs', role_code=RoleCode.FINANCE_SUPPORT,
                assigned_by='cs', assigned_at=now))
        activation = StaffActivationService(core[1],
            phone_otp=PhoneOtpService(core[1], sender=RecordingSmsSender(), secret='fixture-secret'),
            email_code_deriver=lambda _: '728415')
        challenge = activation.request(username='cs', password=password)
        activation.confirm(activation_id=challenge['activation_id'], code='728415')
        settings = Settings(_env_file=None, environment='test',
            jwt_secret='fixture-jwt-secret-at-least-thirty-two-bytes')
        tokens = TokenService(core[1], jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
        staff = tokens.issue_admin_pair(user_id='cs', display_name='staff')
        ordinary = tokens.issue_pair(user_id='alice', device_key='fixture', display_name='app')
        service, order_id, token = prepared_order(core)
        app = FastAPI()
        install_error_handlers(app)
        app.include_router(create_recharge_router(settings, core[1], recharge_service=service), prefix='/api/v1')
        def post(path, *, headers, json):
            async def call():
                async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
                    return await client.post(path, headers=headers, json=json)
            return asyncio.run(call())
        headers = {'Authorization':'Bearer '+staff.access_token, 'Idempotency-Key':'http-prepare'}
        route = '/api/v1/recharge/admin/requests/'+order_id
        prepared = post(route+'/prepare-settlement', headers=headers,
            json={'claim_token':token, 'final_rate':'7.123456'})
        assert prepared.status_code == 200, prepared.text
        assert prepared.json()['settlement_approval_required'] is False
        assert prepared.json()['binding_final_rate'] == '7.123456'
        assert Decimal(prepared.json()['binding_final_caibi_amount']) == Decimal('71.23')
        denied = post(route+'/execute-settlement',
            headers={**headers,'Authorization':'Bearer '+ordinary.access_token}, json={'claim_token':token})
        assert denied.status_code == 403, denied.text
        with core[1].begin() as session:
            session.get(User, 'cs').status = 'DISABLED'
        disabled = post(route+'/execute-settlement', headers=headers, json={'claim_token':token})
        assert disabled.status_code in (401,403), disabled.text
        assert service.ledger.balance('alice') == 0
        with core[1].begin() as session:
            session.get(User, 'cs').status = 'ACTIVE'
        credited = post(route+'/execute-settlement', headers=headers, json={'claim_token':token})
        assert credited.status_code == 200, credited.text
        assert credited.json()['status'] == 'CREDITED'
        assert service.ledger.balance('alice') == Decimal('71.23')
    finally:
        generator.close()
