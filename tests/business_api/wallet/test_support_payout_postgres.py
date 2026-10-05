"""Optional isolated PostgreSQL process race; never a production database."""
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import multiprocessing
import os
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, delete, select, text, update
from sqlalchemy.engine import make_url
from sqlalchemy.exc import DBAPIError, IntegrityError

import test_manual_payouts as original
from test_support_payout import caibi_order, prepare, scoped


def test_postgres_unallocated_receipt_refuses_cross_user_ambiguity(scoped):
    from test_support_payout_discovery import test_final_receipt_rejects_unallocated_event_with_overlapping_order
    test_final_receipt_rejects_unallocated_event_with_overlapping_order(scoped,'manual')


def test_postgres_evidence_takeover_preserves_original_payer_and_revokes_token(scoped):
    from test_support_payout_takeover import test_started_takeover_only_evidence_revokes_old_token_and_preserves_payment
    test_started_takeover_only_evidence_revokes_old_token_and_preserves_payment(scoped)


def test_postgres_selection_uses_durable_candidate_and_settlement(scoped,monkeypatch):
    from test_support_payout_discovery import test_selection_rechecks_discovery_version_then_uses_common_settlement
    test_selection_rechecks_discovery_version_then_uses_common_settlement(scoped,monkeypatch)


def _takeover_worker(raw_url,now_text,official,claims,order_id,key,barrier):
    from app.core.database import create_session_factory
    from app.core.errors import AppError
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutPolicy,ManualPayoutService
    from app.modules.wallet.support_payout import SupportPayoutService
    engine=create_engine(raw_url)
    now=datetime.fromisoformat(now_text)
    payout=ManualPayoutService(create_session_factory(engine),official_config=OfficialFundingConfig(official,'official-v1'),
        policy=ManualPayoutPolicy('test-v1',timedelta(minutes=5),Decimal('100'),Decimal('200'),Decimal('500')),
        owner_admin_id='owner',mfa_verifier=lambda **kw:False,finality=None,clock=lambda:now)
    service=SupportPayoutService(payout,SimpleNamespace(wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner',wallet_real_mode='manual_tron',wallet_access_grant_enabled=True))
    barrier.wait(timeout=30)
    try:
        result=service.takeover(claims=claims,order_id=order_id,expected_claim_version=1,
            reason_code='SUPPORT_OWNER_RECOVERY',idempotency_key=key,owner_authorize=lambda session:lambda:None)
        return {'claim_version':result['claim_version'],'pid':os.getpid()}
    except AppError as error:
        return {'error':error.code,'pid':os.getpid()}
    finally:
        engine.dispose()


def test_independent_owner_takeovers_have_single_version_winner(scoped):
    from test_manual_payouts import request
    core,service,claims=scoped
    order=request(core)
    service.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='race-old')
    context=multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier=manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2,mp_context=context) as executor:
            tasks=[executor.submit(_takeover_worker,core[0].pg_test_url,core[2][0].isoformat(),core[4],
                claims['owner'],order['id'],'owner-race-'+str(index),barrier) for index in range(2)]
            results=[task.result(timeout=60) for task in tasks]
    assert len({result['pid'] for result in results})==2
    assert sum(result.get('claim_version')==2 for result in results)==1,results
    assert [result['error'] for result in results if 'error' in result]==['SUPPORT_PAYOUT_CLAIM_VERSION_CONFLICT']


@pytest.fixture
def legacy_schema(monkeypatch):
    """A 0092 database with old rows, upgraded only after those rows exist."""
    raw = os.environ.get('SUPPORT_PAYOUT_TEST_DATABASE_URL')
    if not raw:
        pytest.skip('isolated support payout PostgreSQL URL not supplied')
    url = make_url(raw)
    if url.host not in ('127.0.0.1', 'localhost') or url.database != 'support_payout_review':
        raise RuntimeError('only the dedicated local support_payout_review database is allowed')
    from alembic import command
    from alembic.config import Config
    service_path = Path(__file__).resolve().parents[3] / 'services' / 'business-api'
    schema = 'support_payout_legacy_' + uuid4().hex
    admin = create_engine(url, isolation_level='AUTOCOMMIT')
    with admin.connect() as connection:
        connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    schema_url = url.update_query_dict({'options': '-csearch_path=' + schema})
    engine = create_engine(schema_url)
    config = Config(str(service_path / 'alembic.ini'))
    config.set_main_option('script_location', str(service_path / 'migrations'))
    config.set_main_option('path_separator', 'os')
    config.set_main_option('sqlalchemy.url', schema_url.render_as_string(hide_password=False).replace('%', '%%'))
    monkeypatch.delenv('BUSINESS_DATABASE_URL', raising=False)
    try:
        command.upgrade(config, '0092_admin_session_entry_mode')
        yield engine, config
    finally:
        engine.dispose()
        with admin.connect() as connection:
            connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()


def test_0092_upgrade_retains_old_payout_and_recharge_rows(legacy_schema):
    from alembic import command

    engine, config = legacy_schema
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(text("""
            INSERT INTO wallet_manual_payout_quotes
                (id, user_id, amount, snapshot, digest, created_at, expires_at)
            VALUES ('legacy-quote', 'legacy-user', 10.000000, '{}', :digest, :now, :expires)
        """), {'digest': 'a' * 64, 'now': now, 'expires': now + timedelta(hours=1)})
        connection.execute(text("""
            INSERT INTO wallet_manual_payout_orders
                (id, quote_id, user_id, amount, digest, status, created_at, updated_at)
            VALUES ('legacy-order', 'legacy-quote', 'legacy-user', 10.000000,
                :digest, 'REQUESTED', :now, :now)
        """), {'digest': 'a' * 64, 'now': now})
        connection.execute(text("""
            INSERT INTO wallet_support_payout_states
                (order_id, expires_at, version, review_required)
            VALUES ('legacy-order', :expires, 3, false)
        """), {'expires': now + timedelta(hours=2)})
        connection.execute(text("""
            INSERT INTO users
                (id, username, username_normalized, email, email_normalized,
                 nickname, profile_updated_at, password_hash, status, created_at, updated_at)
            VALUES ('legacy-user', 'legacy-user', 'legacy-user',
                'legacy@example.test', 'legacy@example.test', 'Legacy User', :now,
                'unused', 'ACTIVE', :now, :now)
        """), {'now': now})
        connection.execute(text("""
            INSERT INTO recharge_requests
                (id, user_id, amount_usdt, status, created_at, updated_at)
            VALUES ('legacy-recharge', 'legacy-user', 10.000000, 'SUBMITTED', :now, :now)
        """), {'now': now})

    command.upgrade(config, 'head')
    with engine.begin() as connection:
        connection.execute(text("""
            INSERT INTO wallet_support_payout_rate_preparations
                (id, order_id, version, rate, receive, digest, reason_code, actor_id, created_at)
            VALUES ('legacy-preparation', 'legacy-order', 1, 1.000000, 10.000000,
                :digest, 'RATE_REVIEWED', 'legacy-staff', :now)
        """), {'digest': 'b' * 64, 'now': now})
        connection.execute(text("""
            INSERT INTO wallet_support_payout_rejections
                (id, order_id, actor_id, reason_code, created_at)
            VALUES ('legacy-rejection', 'legacy-order', 'legacy-staff',
                'INVALID_DESTINATION', :now)
        """), {'now': now})
    command.upgrade(config, 'head')
    with engine.connect() as connection:
        row = connection.execute(text("""
            SELECT version, prepared_rate, prepared_receive, prepared_digest,
                   prepared_version, evidence_actor_id, evidence_token_hash,
                   evidence_version
            FROM wallet_support_payout_states WHERE order_id = 'legacy-order'
        """)).one()
        assert row == (3, None, None, None, 0, None, None, 0)
        assert connection.scalar(text("""
            SELECT claim_version FROM recharge_requests WHERE id = 'legacy-recharge'
        """)) == 0
        assert connection.scalar(text("""
            SELECT count(*) FROM wallet_support_payout_rate_preparations
            WHERE id = 'legacy-preparation'
        """)) == 1
        assert connection.scalar(text("""
            SELECT count(*) FROM wallet_support_payout_rejections
            WHERE id = 'legacy-rejection'
        """)) == 1
        assert connection.scalar(text('SELECT version_num FROM alembic_version')) == '0095_wallet_source_alerts'


def test_preparation_and_rejection_history_reject_duplicates_and_mutation(scoped):
    from app.modules.wallet.support_payout import SupportPayoutRatePreparation, SupportPayoutRejection
    from test_manual_payouts import request

    core, _, _ = scoped
    order = request(core)
    now = core[2][0]
    preparation = SupportPayoutRatePreparation(id='prepared-1', order_id=order['id'], version=1,
        rate=Decimal('1.000000'), receive=Decimal('10.000000'), digest='b' * 64,
        reason_code='RATE_REVIEWED', actor_id='bob', created_at=now)
    next_preparation = SupportPayoutRatePreparation(id='prepared-next', order_id=order['id'], version=2,
        rate=Decimal('1.100000'), receive=Decimal('11.000000'), digest='c' * 64,
        reason_code='RATE_REVIEWED', actor_id='bob', created_at=now)
    rejection = SupportPayoutRejection(id='rejected-1', order_id=order['id'],
        actor_id='bob', reason_code='INVALID_DESTINATION', created_at=now)
    with core[1].begin() as session:
        session.add_all((preparation, next_preparation, rejection))
    with core[1]() as session:
        assert len(session.scalars(select(SupportPayoutRatePreparation).where(
            SupportPayoutRatePreparation.order_id == order['id'])).all()) == 2

    with pytest.raises(IntegrityError):
        with core[1].begin() as session:
            session.add(SupportPayoutRatePreparation(id='prepared-2', order_id=order['id'], version=1,
                rate=Decimal('1.200000'), receive=Decimal('12.000000'), digest='d' * 64,
                reason_code='RATE_REVIEWED', actor_id='owner', created_at=now))
    with pytest.raises(IntegrityError):
        with core[1].begin() as session:
            session.add(SupportPayoutRejection(id='rejected-2', order_id=order['id'],
                actor_id='owner', reason_code='INVALID_DESTINATION', created_at=now))

    engine = core[1].kw['bind']
    for model, table, identifier in (
        (SupportPayoutRatePreparation, 'wallet_support_payout_rate_preparations', 'prepared-1'),
        (SupportPayoutRejection, 'wallet_support_payout_rejections', 'rejected-1'),
    ):
        with pytest.raises(ValueError, match='append-only'):
            with core[1].begin() as session:
                session.get(model, identifier).reason_code = 'TAMPERED'
        with pytest.raises(ValueError, match='append-only'):
            with core[1].begin() as session:
                session.delete(session.get(model, identifier))
        with pytest.raises(ValueError, match='append-only'):
            with core[1].begin() as session:
                session.execute(update(model).where(model.id == identifier).values(reason_code='TAMPERED'))
        with pytest.raises(ValueError, match='append-only'):
            with core[1].begin() as session:
                session.execute(delete(model).where(model.id == identifier))
        for sql in (
            f'UPDATE {table} SET reason_code = \'TAMPERED\' WHERE id = :identifier',
            f'DELETE FROM {table} WHERE id = :identifier',
        ):
            with pytest.raises(DBAPIError, match='append-only'):
                with engine.begin() as connection:
                    connection.execute(text(sql), {'identifier': identifier})
        with engine.connect() as connection:
            assert connection.scalar(text(f'SELECT count(*) FROM {table} WHERE id = :identifier'),
                {'identifier': identifier}) == 1


@pytest.fixture
def core(monkeypatch):
    raw=os.environ.get('SUPPORT_PAYOUT_TEST_DATABASE_URL')
    if not raw: pytest.skip('isolated support payout PostgreSQL URL not supplied')
    url=make_url(raw)
    if url.host not in ('127.0.0.1','localhost') or url.database!='support_payout_review':
        raise RuntimeError('only the dedicated local support_payout_review database is allowed')
    schema='support_payout_'+uuid4().hex
    admin=create_engine(url,isolation_level='AUTOCOMMIT')
    with admin.connect() as connection: connection.execute(text(f'CREATE SCHEMA "{schema}"'))
    schema_url=url.update_query_dict({'options':'-csearch_path='+schema})
    engine=create_engine(schema_url)
    generator=None
    try:
        from alembic import command
        from alembic.config import Config
        from app.core.database import Base
        service_path=Path(__file__).resolve().parents[3]/'services'/'business-api'
        config=Config(str(service_path/'alembic.ini'))
        config.set_main_option('script_location',str(service_path/'migrations'))
        config.set_main_option('path_separator','os')
        config.set_main_option('sqlalchemy.url',schema_url.render_as_string(hide_password=False).replace('%','%%'))
        monkeypatch.delenv('BUSINESS_DATABASE_URL',raising=False)
        command.upgrade(config,'head')
        # Replace only seed controls in this newly created rehearsal schema.
        with engine.begin() as connection:
            connection.execute(text('DELETE FROM wallet_controls'))
            connection.execute(text('DELETE FROM ledger_redeemability_reserve'))
        monkeypatch.setattr(Base.metadata,'create_all',lambda *args,**kwargs:None)
        monkeypatch.setattr(original,'create_engine',lambda *args,**kwargs:engine)
        generator=original.core.__wrapped__()
        value=next(generator)
        value[0].pg_test_url=schema_url.render_as_string(hide_password=False)
        yield value
    finally:
        if generator: generator.close()
        engine.dispose()
        with admin.connect() as connection: connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
        admin.dispose()


def _claim_worker(raw_url,now_text,official,claims,order_id,barrier):
    from app.core.database import create_session_factory
    from app.core.errors import AppError
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutPolicy,ManualPayoutService
    from app.modules.wallet.support_payout import SupportPayoutService
    engine=create_engine(raw_url)
    now=datetime.fromisoformat(now_text)
    payout=ManualPayoutService(create_session_factory(engine),official_config=OfficialFundingConfig(official,'official-v1'),
        policy=ManualPayoutPolicy('test-v1',timedelta(minutes=5),Decimal('100'),Decimal('200'),Decimal('500')),
        owner_admin_id='owner',mfa_verifier=lambda **kw:False,finality=None,clock=lambda:now)
    service=SupportPayoutService(payout,SimpleNamespace(wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner',wallet_real_mode='manual_tron',wallet_access_grant_enabled=True))
    barrier.wait(timeout=30)
    try:
        result=service.claim(claims=claims,order_id=order_id,idempotency_key='process-race-'+claims['sub'])
        return {'winner':claims['sub'],'claim_token':result['claim_token'],'pid':os.getpid()}
    except AppError as error:
        return {'error':error.code,'pid':os.getpid()}
    finally:
        engine.dispose()


def test_independent_processes_have_exactly_one_payout_lease(scoped):
    from app.core.errors import AppError
    from test_manual_payouts import request
    core,service,claims=scoped
    order=request(core)
    context=multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier=manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2,mp_context=context) as executor:
            tasks=[executor.submit(_claim_worker,core[0].pg_test_url,core[2][0].isoformat(),core[4],
                claims[uid],order['id'],barrier) for uid in ('owner','bob')]
            results=[task.result(timeout=60) for task in tasks]
    assert len({result['pid'] for result in results})==2
    winners=[result for result in results if 'winner' in result]
    assert len(winners)==1,results
    assert [result['error'] for result in results if 'error' in result]==['SUPPORT_PAYOUT_ALREADY_CLAIMED']
    winner=winners[0]
    loser='owner' if winner['winner']=='bob' else 'bob'
    core[2][0]+=timedelta(minutes=5)
    takeover=service.claim(claims=claims[loser],order_id=order['id'],idempotency_key='takeover')
    assert takeover['claimed_by']==loser
    with pytest.raises(AppError,match='SUPPORT_PAYOUT_CLAIM_REQUIRED'):
        service.heartbeat(claims=claims[winner['winner']],order_id=order['id'],claim_token=winner['claim_token'])


def _activation_worker(raw_url,now_text,activation_id,barrier):
    from app.core.database import create_session_factory
    from app.core.errors import AppError
    from app.modules.identity.phone import PhoneOtpService,RecordingSmsSender
    from app.modules.identity.staff_activation import StaffActivationService
    engine=create_engine(raw_url)
    factory=create_session_factory(engine)
    now=datetime.fromisoformat(now_text)
    otp=PhoneOtpService(factory,sender=RecordingSmsSender(),secret='isolated-pg-otp-secret',now=lambda:now)
    service=StaffActivationService(factory,phone_otp=otp,email_code_deriver=lambda value:'846291',now=lambda:now)
    barrier.wait(timeout=30)
    try:
        service.confirm(activation_id=activation_id,code='846291')
        return {'status':'activated','pid':os.getpid()}
    except AppError as error:
        return {'error':error.code,'pid':os.getpid()}
    finally:
        engine.dispose()


def test_independent_processes_consume_activation_otp_only_once(scoped):
    from app.modules.identity.phone import PhoneOtpService,RecordingSmsSender
    from app.modules.identity.staff_activation import StaffActivation,StaffActivationService
    core,_,_=scoped
    with core[1].begin() as session: session.delete(session.get(StaffActivation,'bob'))
    otp=PhoneOtpService(core[1],sender=RecordingSmsSender(),secret='isolated-pg-otp-secret',now=lambda:core[2][0])
    service=StaffActivationService(core[1],phone_otp=otp,email_code_deriver=lambda value:'846291',now=lambda:core[2][0])
    issued=service.request(username='bob',password='correct login password')
    context=multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier=manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2,mp_context=context) as executor:
            futures=[executor.submit(_activation_worker,core[0].pg_test_url,core[2][0].isoformat(),issued['activation_id'],barrier) for _ in range(2)]
            results=[future.result(timeout=60) for future in futures]
    assert len({result['pid'] for result in results})==2
    assert sum(result.get('status')=='activated' for result in results)==1,results
    assert len([result for result in results if result.get('error') in ('OTP_INVALID','STAFF_ACTIVATION_INVALID')])==1


def _rate_worker(raw_url, now_text, official, claims, order_id, token, rate, barrier):
    from app.core.database import create_session_factory
    from app.core.errors import AppError
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutPolicy, ManualPayoutService
    from app.modules.wallet.support_payout import SupportPayoutService
    engine = create_engine(raw_url)
    now = datetime.fromisoformat(now_text)
    payout = ManualPayoutService(create_session_factory(engine),
        official_config=OfficialFundingConfig(official, 'official-v1'),
        policy=ManualPayoutPolicy('test-v1', timedelta(minutes=5), Decimal('100'), Decimal('200'), Decimal('500')),
        owner_admin_id='owner', mfa_verifier=lambda **kw: False, finality=None, clock=lambda: now)
    service = SupportPayoutService(payout, SimpleNamespace(wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_real_mode='manual_tron', wallet_access_grant_enabled=True))
    barrier.wait(timeout=30)
    try:
        result = service.adjust_rate(claims=claims, order_id=order_id, claim_token=token,
            new_rate=rate, reason_code='RATE_REVIEWED', expected_preparation_version=0,
            idempotency_key='race-rate-'+rate)
        return {'prepared_version': result['prepared_version'], 'pid': os.getpid()}
    except AppError as error:
        return {'error': error.code, 'pid': os.getpid()}
    finally:
        engine.dispose()


def test_independent_rate_preparations_have_one_version_winner(scoped):
    from app.modules.wallet.support_payout import SupportPayoutRatePreparation, SupportPayoutState
    core, _, claims = scoped
    order, lease = caibi_order(scoped)
    context = multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier = manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2, mp_context=context) as executor:
            futures = [executor.submit(_rate_worker, core[0].pg_test_url, core[2][0].isoformat(),
                core[4], claims['bob'], order['id'], lease['claim_token'], rate, barrier)
                for rate in ('7.500000', '8.000000')]
            results = [future.result(timeout=60) for future in futures]
    assert len({result['pid'] for result in results}) == 2
    assert sum(result.get('prepared_version') == 1 for result in results) == 1, results
    assert [result['error'] for result in results if 'error' in result] == ['WALLET_PAYOUT_PREPARATION_CONFLICT']
    with core[1]() as session:
        assert session.get(SupportPayoutState, order['id']).prepared_version == 1
        assert len(session.scalars(select(SupportPayoutRatePreparation).where(
            SupportPayoutRatePreparation.order_id == order['id'])).all()) == 1
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'REQUESTED'
    assert core[5].balance('HOLD:alice') == Decimal('20')


def _begin_or_cancel_worker(raw_url, now_text, official, claims, order_id, token,
                            digest, version, operation, barrier):
    from app.core.database import create_session_factory
    from app.core.errors import AppError
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutPolicy, ManualPayoutService
    from app.modules.wallet.support_payout import SupportPayoutService
    engine = create_engine(raw_url)
    now = datetime.fromisoformat(now_text)
    payout = ManualPayoutService(create_session_factory(engine),
        official_config=OfficialFundingConfig(official, 'official-v1'),
        policy=ManualPayoutPolicy('test-v1', timedelta(minutes=5), Decimal('100'), Decimal('200'), Decimal('500')),
        owner_admin_id='owner', mfa_verifier=lambda **kw: False, finality=None, clock=lambda: now)
    service = SupportPayoutService(payout, SimpleNamespace(wallet_admin_auth_mode='operation_password',
        wallet_manual_owner_admin_id='owner', wallet_real_mode='manual_tron', wallet_access_grant_enabled=True))
    barrier.wait(timeout=30)
    try:
        if operation == 'begin':
            result = service.begin_payment(claims=claims, order_id=order_id, claim_token=token,
                expected_digest=digest, expected_preparation_version=version,
                idempotency_key='race-begin-'+str(version))
        elif operation == 'reject':
            result = service.reject(claims=claims, order_id=order_id, claim_token=token,
                reason_code='PAYOUT_ADDRESS_INVALID', idempotency_key='race-reject')
        else:
            result = payout.cancel(user_id='alice', order_id=order_id, idempotency_key='race-cancel')
        return {'status': result['status'], 'operation': operation, 'pid': os.getpid()}
    except AppError as error:
        return {'error': error.code, 'operation': operation, 'pid': os.getpid()}
    finally:
        engine.dispose()


def test_independent_cancel_and_begin_have_one_financial_winner(scoped):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    from app.modules.wallet.support_payout import SupportPayoutState
    from test_manual_payouts import request
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='race-lease')
    context = multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier = manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2, mp_context=context) as executor:
            futures = [executor.submit(_begin_or_cancel_worker, core[0].pg_test_url, core[2][0].isoformat(),
                core[4], claims['bob'], order['id'], lease['claim_token'], order['digest'], None,
                operation, barrier)
                for operation in ('begin', 'cancel')]
            results = [future.result(timeout=60) for future in futures]
    assert len({result['pid'] for result in results}) == 2
    winners = [result for result in results if 'status' in result]
    assert len(winners) == 1, results
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        assert row.status in {'CLAIMED', 'CANCELLED'}
        assert (state.execution_started_at is not None) == (row.status == 'CLAIMED')
    assert core[5].balance('HOLD:alice') == (Decimal('10') if row.status == 'CLAIMED' else Decimal('0'))


def test_independent_cancel_reject_begin_have_one_financial_winner(scoped):
    from app.modules.wallet.manual_payout_models import ManualPayoutOrder
    from app.modules.wallet.support_payout import SupportPayoutRejection, SupportPayoutState
    from test_manual_payouts import request
    core, service, claims = scoped
    order = request(core)
    lease = service.claim(claims=claims['bob'], order_id=order['id'], idempotency_key='three-way-lease')
    context = multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier = manager.Barrier(3)
        with ProcessPoolExecutor(max_workers=3, mp_context=context) as executor:
            futures = [executor.submit(_begin_or_cancel_worker, core[0].pg_test_url, core[2][0].isoformat(),
                core[4], claims['bob'], order['id'], lease['claim_token'], order['digest'], None,
                operation, barrier) for operation in ('begin', 'cancel', 'reject')]
            results = [future.result(timeout=60) for future in futures]
    assert len({result['pid'] for result in results}) == 3
    winners = [result for result in results if 'status' in result]
    assert len(winners) == 1, results
    with core[1]() as session:
        row = session.get(ManualPayoutOrder, order['id'])
        state = session.get(SupportPayoutState, order['id'])
        rejection = session.scalar(select(SupportPayoutRejection).where(
            SupportPayoutRejection.order_id == order['id']))
        assert row.status in {'CLAIMED', 'CANCELLED'}
        assert (state.execution_started_at is not None) == (row.status == 'CLAIMED')
        assert (rejection is not None) == (winners[0]['operation'] == 'reject')
    assert core[5].balance('HOLD:alice') == (Decimal('10') if row.status == 'CLAIMED' else Decimal('0'))


def test_independent_stale_tab_cannot_begin_after_latest_preparation(scoped):
    core, service, claims = scoped
    order, lease = caibi_order(scoped)
    first = prepare(scoped, order, lease, rate='8.000000', version=0, key='first-pg-rate')
    latest = prepare(scoped, order, lease, rate='7.500000', version=1, key='latest-pg-rate')
    context = multiprocessing.get_context('spawn')
    with context.Manager() as manager:
        barrier = manager.Barrier(2)
        with ProcessPoolExecutor(max_workers=2, mp_context=context) as executor:
            futures = [executor.submit(_begin_or_cancel_worker, core[0].pg_test_url, core[2][0].isoformat(),
                core[4], claims['bob'], order['id'], lease['claim_token'], digest, version,
                'begin', barrier) for digest, version in (
                    (first['prepared_digest'], 1), (latest['prepared_digest'], 2))]
            results = [future.result(timeout=60) for future in futures]
    assert len({result['pid'] for result in results}) == 2
    assert sum(result.get('status') == 'CLAIMED' for result in results) == 1, results
    assert [result['error'] for result in results if 'error' in result][0] in {
        'WALLET_PAYOUT_PREPARATION_CONFLICT', 'WALLET_PAYOUT_ALREADY_CLAIMED'}
    assert core[0].status(user_id='alice', order_id=order['id'])['status'] == 'CLAIMED'
    assert core[5].balance('HOLD:alice') == Decimal('18.986667')


def test_postgres_void_remains_terminal_after_evidence_takeover(scoped):
    from test_support_payout_void_compatibility import test_published_void_preserves_payer_and_revokes_all_support_capabilities
    test_published_void_preserves_payer_and_revokes_all_support_capabilities(scoped)
