"""Real two-session PostgreSQL tests for the protected void transition."""
import ast
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from pathlib import Path
from threading import Barrier
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, select, text, func

import test_manual_payouts as fixtures
from app.core.errors import AppError
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from app.modules.wallet.models import WalletLedgerTransaction


_fixture_tables=[]

@pytest.fixture
def pgcore(monkeypatch):
    url=os.getenv('REPORTING_PG_URL')
    if not url:
        pytest.skip('REPORTING_PG_URL required for isolated PostgreSQL concurrency')
    schema='void_race_'+uuid4().hex
    admin=create_engine(url)
    with admin.begin() as connection:
        connection.execute(text('CREATE SCHEMA '+schema))
    engine=create_engine(url, connect_args={'options':'-csearch_path='+schema})
    monkeypatch.setattr(fixtures,'create_engine',lambda *args,**kwargs:engine)
    original_create_all=fixtures.Base.metadata.create_all
    def create_fixture_tables(bind):
        if not _fixture_tables:
            _fixture_tables.extend(fixtures.Base.metadata.tables.values())
        original_create_all(bind,tables=_fixture_tables)
    monkeypatch.setattr(fixtures.Base.metadata,'create_all',create_fixture_tables)
    generator=fixtures.core.__wrapped__()
    try:
        core=next(generator)
        migration=Path(__file__).resolve().parents[3]/'services/business-api/migrations/versions/0093_unbroadcast_payout_void.py'
        tree=ast.parse(migration.read_text(encoding='utf-8'))
        sql=next(node.args[0].value for node in ast.walk(tree) if isinstance(node,ast.Call)
            and isinstance(node.func,ast.Attribute) and node.func.attr=='execute'
            and node.args and isinstance(node.args[0],ast.Constant))
        with engine.begin() as connection:
            connection.execute(text(sql))
            connection.execute(text('CREATE TRIGGER manual_order_guard BEFORE UPDATE OR DELETE ON '
                'wallet_manual_payout_orders FOR EACH ROW EXECUTE FUNCTION wallet_manual_order_guard()'))
        yield core
    finally:
        generator.close()
        engine.dispose()
        with admin.begin() as connection:
            connection.execute(text('DROP SCHEMA '+schema+' CASCADE'))
        admin.dispose()


def void_arguments(core,order):
    with core[1]() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        version,claim_ms=row.version,int(row.claimed_at.timestamp()*1000)
    now=core[2][0]
    proof=dict(source_id='fixture-source',observation_id='pg-1',checkpoint=int(now.timestamp()*1000),
        observed_at=now,scanned_from=claim_ms,reconciliation_status='SOURCE_MATCHED',matching_outflows=0,
        suspicious_outflows=0,fresh_until_ms=int((now+timedelta(seconds=60)).timestamp()*1000),max_rowid=1)
    return dict(admin_id='owner',order_id=order['id'],expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED',never_signed=True,never_broadcast=True,idempotency_key='race-void',
        evidence=proof,authorize=lambda session:lambda:None,verify_evidence=lambda session,evidence:True)


def test_two_void_commands_compensate_once_under_postgres_locks(pgcore):
    core=pgcore;order=fixtures.claim(core)
    assert core[0].reconcile(order_id=order['id'])['status']=='UNKNOWN'
    args=void_arguments(core,order);barrier=Barrier(2)
    def run():
        barrier.wait(timeout=5)
        return core[0].void_unbroadcast(**args)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results=list(pool.map(lambda _:run(),range(2)))
    assert results[0]==results[1] and results[0]['status']=='VOIDED'
    assert core[5].balance('HOLD:alice')==0 and core[5].balance('alice')==1000
    with core[1]() as session:
        assert session.get(RedeemabilityReserve,'global').pending_payouts==0
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction).where(
            WalletLedgerTransaction.scope=='wallet.manual_void_release'))==1


def test_void_racing_candidate_and_settlement_has_one_financial_result(pgcore):
    core=pgcore;order=fixtures.claim(core)
    assert core[0].reconcile(order_id=order['id'])['status']=='UNKNOWN'
    core[6].evidence=fixtures.evidence(core)
    args=void_arguments(core,order);barrier=Barrier(2)
    def void():
        barrier.wait(timeout=5)
        try:return core[0].void_unbroadcast(**args)['status']
        except AppError:return 'REJECTED'
    def settle():
        barrier.wait(timeout=5)
        try:
            core[0].submit_txid(admin_id='owner',order_id=order['id'],txid='a'*64,idempotency_key='race-tx')
            return core[0].reconcile(order_id=order['id'])['status']
        except AppError:return 'REJECTED'
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(void),pool.submit(settle)]
        outcomes=[f.result(timeout=15) for f in futures]
    final=core[0].status(user_id='alice',order_id=order['id'])['status']
    assert final in {'VOIDED','SETTLED'} and outcomes.count('REJECTED')==1
    assert core[5].balance('HOLD:alice')==0
    assert core[5].balance('alice')==(1000 if final=='VOIDED' else 990)
    with core[1]() as session:
        assert session.get(RedeemabilityReserve,'global').pending_payouts==0
        scopes=list(session.scalars(select(WalletLedgerTransaction.scope).where(
            WalletLedgerTransaction.scope.in_(['wallet.manual_void_release','wallet.manual_settle']))))
        assert len(scopes)==1
