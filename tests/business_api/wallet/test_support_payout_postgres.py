"""Optional isolated PostgreSQL process race; never a production database."""
from concurrent.futures import ProcessPoolExecutor
from datetime import datetime, timedelta
from decimal import Decimal
import multiprocessing
import os
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

import test_manual_payouts as original
from test_support_payout import scoped


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
