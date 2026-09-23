"""Run only against the explicitly provided isolated PostgreSQL database."""
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from uuid import uuid4
import pytest
from sqlalchemy import create_engine, inspect
from sqlalchemy.orm import sessionmaker
import app.main  # noqa: F401
from app.core.database import Base
from app.core.errors import AppError
from app.modules.identity.models import User
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeRequest
from app.modules.recharge.service import RechargeService


@pytest.fixture
def pg():
    url=os.environ.get('SUPPORT_ORDER_POSTGRES_URL')
    if not url:
        pytest.skip('isolated PostgreSQL URL not provided')
    engine=create_engine(url,pool_size=10)
    assert engine.dialect.name=='postgresql'
    assert inspect(engine).has_table('alembic_version'), 'run full migrations on the isolated DB first'
    factory=sessionmaker(engine,expire_on_commit=False)
    uid='u-'+uuid4().hex[:24]
    clock=[datetime.now(timezone.utc)]
    with factory.begin() as session:
        session.add(User(id=uid,username=uid,username_normalized=uid,password_hash='unused',
            status='ACTIVE',created_at=clock[0],updated_at=clock[0]))
    service=RechargeService(factory,ledger=LedgerService(factory),now=lambda:clock[0],
        official_config=SimpleNamespace(address='isolated-fixture-official',version='v1'))
    order=service.submit(user_id=uid,amount_usdt=Decimal('10'),idempotency_key='new')
    yield service,order['id'],clock,factory
    engine.dispose()


def test_eight_independent_database_sessions_share_one_durable_claim(pg):
    service,identity,_,factory=pg
    def attempt(index):
        try:
            return service.claim_order(request_id=identity,actor_id=f'cs-{index}',idempotency_key=identity)
        except AppError as error:
            return error.code
    with ThreadPoolExecutor(max_workers=8) as pool:
        results=list(pool.map(attempt,range(8)))
    winners=[result for result in results if isinstance(result,dict)]
    assert len(winners)==1
    assert results.count('RECHARGE_CLAIMED_BY_OTHER')==7
    with factory() as session:
        assert session.get(RechargeRequest,identity).claimed_by==winners[0]['claimed_by']


def test_deadline_projection_and_worker_are_idempotent(pg):
    service,identity,clock,factory=pg
    clock[0]+=timedelta(hours=2)
    assert service.expire_orders()>=1
    assert service.expire_orders()==0
    with pytest.raises(AppError) as error:
        service.claim_order(request_id=identity,actor_id='cs-expired',idempotency_key=identity)
    assert error.value.code=='RECHARGE_REVIEW_REQUIRED'
    recovered=service.claim_order(request_id=identity,actor_id='cs-review',idempotency_key=identity,
        review=True,reason='核对迟到账')
    assert recovered['processing_stage']=='REVIEWING'
    with factory() as session:
        row=session.get(RechargeRequest,identity)
        assert row.status=='SUBMITTED' and row.ledger_transaction_id is None
