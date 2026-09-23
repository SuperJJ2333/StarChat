from datetime import datetime,timedelta,timezone
from decimal import Decimal
from types import SimpleNamespace
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
import app.main
from app.core.database import Base
from app.core.errors import AppError
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus
from app.modules.ledger.service import LedgerService
from app.modules.recharge.service import RechargeService

@pytest.fixture
def flow(tmp_path):
    engine=create_engine('sqlite:///'+str(tmp_path/'flow.db'),connect_args={'check_same_thread':False,'timeout':10})
    Base.metadata.create_all(engine)
    factory=sessionmaker(engine,expire_on_commit=False)
    clock=[datetime(2026,9,23,tzinfo=timezone.utc)]
    with factory.begin() as s:
        for name in ('alice','bob','cs1','cs2'):
            s.add(User(id=name,username=name,username_normalized=name,email=name+'@example.test',email_normalized=name+'@example.test',password_hash='unused',status=AccountStatus.ACTIVE,created_at=clock[0],updated_at=clock[0]))
    service=RechargeService(factory,ledger=LedgerService(factory),now=lambda:clock[0])
    service.official_config=SimpleNamespace(address='official-test-address',version='v1')
    yield service,clock,factory
    engine.dispose()

def submit(service,key='one'):
    return service.submit(user_id='alice',amount_usdt=Decimal('10'),idempotency_key=key)

def test_claim_excludes_other_staff_and_stale_token_after_lease(flow):
    service,clock,_=flow;order=submit(service)
    first=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='c1')
    with pytest.raises(AppError) as err:
        service.claim_order(request_id=order['id'],actor_id='cs2',idempotency_key='c2')
    assert err.value.code=='RECHARGE_CLAIMED_BY_OTHER'
    clock[0]+=timedelta(minutes=6)
    second=service.claim_order(request_id=order['id'],actor_id='cs2',idempotency_key='c3')
    assert first['claim_token']!=second['claim_token']
    with pytest.raises(AppError) as err:
        service.heartbeat_order(request_id=order['id'],actor_id='cs1',claim_token=first['claim_token'])
    assert err.value.code=='RECHARGE_CLAIM_LOST'

def test_unverified_order_cannot_bind_and_deadline_becomes_review(flow):
    service,clock,_=flow;order=submit(service)
    assert order['expires_at'] and order['official_payment']['address']=='official-test-address'
    claim=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='c1')
    with pytest.raises(AppError) as err:
        service.bind_finance_adjustment(request_id=order['id'],actor_id='cs1',adjustment_id='anything',final_rate='7',idempotency_key='b1',claim_token=claim['claim_token'])
    assert err.value.code=='RECHARGE_PAYMENT_UNVERIFIED'
    clock[0]+=timedelta(hours=2)
    assert service.list_mine(user_id='alice')[0]['processing_stage']=='NEEDS_REVIEW'
    with pytest.raises(AppError) as err:
        service.claim_order(request_id=order['id'],actor_id='cs2',idempotency_key='c2')
    assert err.value.code=='RECHARGE_REVIEW_REQUIRED'

def test_evidence_submission_is_owned_and_blocks_blind_cancel(flow):
    service,_,_=flow;order=submit(service)
    with pytest.raises(AppError):
        service.submit_evidence(request_id=order['id'],user_id='bob',txid='a'*64,idempotency_key='wrong')
    service.submit_evidence(request_id=order['id'],user_id='alice',txid='a'*64,idempotency_key='proof')
    with pytest.raises(AppError) as err: service.cancel(request_id=order['id'],user_id='alice')
    assert err.value.code=='RECHARGE_PAYMENT_REVIEW_REQUIRED'
