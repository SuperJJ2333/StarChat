"""Portable, network-free Worker regression against synthetic test-owned schemas.

Run inside the actual image with normal imports, no PYTHONPATH override. The
database must be a localhost isolated clone; the probe creates/drops one random
schema and never writes the clone's public data or connects to any provider.
"""
import argparse
from datetime import datetime,timedelta,timezone
from decimal import Decimal
import hashlib
import importlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

from sqlalchemy import create_engine,select,text
from sqlalchemy.engine import make_url


MODULES=(
    'app.modules.wallet.manual_payouts',
    'app.modules.wallet.support_payout',
    'app.modules.wallet.conversions',
    'app.modules.wallet.service',
    'app.modules.ledger.service',
    'tasks.manual_wallet',
)


def register_models():
    for name in MODULES:
        importlib.import_module(name)
    for name in ('app.modules.wallet.repair_models','app.modules.wallet.incident_models'):
        importlib.import_module(name)


def source_identity(expected=None,installed=False):
    result={}
    for name in MODULES:
        module=importlib.import_module(name)
        path=Path(module.__file__).resolve()
        digest=hashlib.sha256(path.read_bytes()).hexdigest()
        if installed:
            if name.startswith('app.'):
                assert '/site-packages/app/' in path.as_posix(),f'{name}: installed package required'
            else:
                assert path.as_posix().startswith('/opt/'),f'{name}: installed Worker task required'
        if expected is not None:
            assert expected.get(name)==digest,f'{name}: imported source SHA mismatch'
        result[name]={'path':path.as_posix(),'sha256':digest}
    return result


def run_cases(factory,*,payout_class=None):
    from coincurve import PrivateKey
    from app.integrations.tron.message_signature import address_from_public_key
    from app.integrations.tron.finality import SolidHead,TransactionEvidence,TransferEvidence
    from app.integrations.tron.reader import USDT_CONTRACT
    from app.modules.wallet.funding import OfficialFundingConfig
    from app.modules.wallet.manual_payouts import ManualPayoutService,ManualPayoutPolicy
    from app.modules.wallet.manual_payout_models import ManualPayoutQuote,ManualPayoutOrder,ManualPayoutCandidate,ManualPayoutEvent
    from app.modules.wallet.support_payout import SupportPayoutState
    from app.modules.wallet.models import WalletControl,WalletLedgerTransaction
    from app.modules.wallet.service import WalletLedger
    from app.modules.ledger.reserve import RedeemabilityReserve
    from app.modules.audit.models import AuditEvent
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    now=datetime.now(timezone.utc)
    start=now-timedelta(minutes=5)
    transfer_at=now-timedelta(minutes=4)
    transfer_ms=int(transfer_at.timestamp()*1000)
    official,target,unique_target,empty_target=[address_from_public_key(PrivateKey(bytes([value])*32).public_key.format(compressed=False))
        for value in (1,2,3,4)]
    with factory.begin() as session:
        session.add(WalletControl(id='global',withdrawals_paused=False))
        session.add(RedeemabilityReserve(id='global',eligible_usdt=Decimal('1000'),usdt_liability=Decimal('0'),
            version=1,pending_payouts=0,outgoing_restricted=False,observed_at=now))
    ledger=WalletLedger(factory)
    ledger.post(entries={'PLATFORM_CUSTODY':Decimal('-40'),**{'HOLD:'+uid:Decimal('10')
        for uid in ('worker-a','worker-b','worker-c','worker-d')}},actor_id='worker-probe',
        reason_code='ISOLATED_TEST_FUND',idempotency_key='worker-probe-seed',scope='worker.probe')
    plans=(('ambiguous-a','worker-a',target,'a'*64),('ambiguous-b','worker-b',target,'a'*64),
        ('unique','worker-c',unique_target,'b'*64),('empty','worker-d',empty_target,None))
    with factory.begin() as session:
        session.get(RedeemabilityReserve,'global').pending_payouts=4
        for order_id,uid,destination,txid in plans:
            snapshot=dict(official_address=official,target_address=destination,receive='10.000000',
                funding_asset='USDT',approval_policy='SUPPORT_MANUAL_V1')
            digest=hashlib.sha256(json.dumps(snapshot,sort_keys=True).encode()).hexdigest()
            session.add(ManualPayoutQuote(id=order_id+'-quote',user_id=uid,amount=Decimal('10'),snapshot=snapshot,
                digest=digest,created_at=start,expires_at=now+timedelta(hours=1)))
        session.flush()
        for order_id,uid,destination,txid in plans:
            terms=session.get(ManualPayoutQuote,order_id+'-quote')
            session.add(ManualPayoutOrder(id=order_id,quote_id=terms.id,user_id=uid,amount=Decimal('10'),
                digest=terms.digest,status='UNKNOWN' if txid else 'CLAIMED',claimed_by='worker-test-support',
                claimed_at=start,candidate_txid=txid,created_at=start,updated_at=start))
        session.flush()
        for order_id,uid,destination,txid in plans:
            session.add(SupportPayoutState(order_id=order_id,expires_at=now+timedelta(hours=1),
                claimed_by='worker-test-support',claim_token='synthetic-token-not-used-for-background-task',
                claim_expires_at=start+timedelta(minutes=1),execution_started_at=start,version=1,review_required=False))
            if txid:
                session.add(ManualPayoutCandidate(id=order_id+'-candidate',order_id=order_id,txid=txid,
                    actor_id='worker-test-support',reason_code='INITIAL_LOCATOR',created_at=start))
    receipts={}
    for txid,destination in (('a'*64,target),('b'*64,unique_target)):
        transfer=TransferEvidence(txid,0,200,'c'*64,transfer_ms,official,destination,10000000,USDT_CONTRACT)
        receipts[txid]=TransactionEvidence(txid,200,'c'*64,transfer_ms,
            SolidHead(201,'d'*64,int(now.timestamp()*1000),now),(transfer,),now)
    requests=[]
    def evidence(txid):
        requests.append(txid)
        return receipts[txid]
    implementation=payout_class or ManualPayoutService
    policy_class=importlib.import_module(implementation.__module__).ManualPayoutPolicy
    payout=implementation(factory,official_config=OfficialFundingConfig(official,'synthetic-v1'),
        policy=policy_class('worker-probe',timedelta(minutes=5),Decimal('100'),Decimal('200'),Decimal('500')),
        owner_admin_id='worker-test-owner',mfa_verifier=lambda **kwargs:False,
        finality=SimpleNamespace(transaction_evidence=evidence),clock=lambda:now)
    scans=[]
    runtime=SimpleNamespace(funds_enabled=False,deposits_enabled=False,payout_requests_enabled=False,payouts=payout)
    scanner=SimpleNamespace(run_once=lambda **kwargs:scans.append(kwargs) or {'status':'DISABLED'})
    task=ManualWalletMaintenanceTask(factory,runtime=runtime,scanner=scanner)
    run=task.run_once()
    assert run['payout_errors']==0 and run['payouts_checked']==4,'actual Worker reconciliation failed'
    with factory() as session:
        ambiguous=[session.get(ManualPayoutOrder,key) for key in ('ambiguous-a','ambiguous-b')]
        assert all(row.status=='UNKNOWN' and row.review_reason=='ORDER_ATTRIBUTION_AMBIGUOUS'
            for row in ambiguous),'Worker must reject ambiguous cross-user receipts'
        events=session.scalars(select(ManualPayoutEvent)).all()
        assert len(events)==1 and events[0].order_id=='unique','only uniquely attributable receipt may allocate an event'
        assert session.get(ManualPayoutOrder,'unique').status=='SETTLED','unique receipt must remain settleable'
        empty=session.get(ManualPayoutOrder,'empty')
        assert empty.status=='CLAIMED' and empty.review_reason is None,'empty candidate must preserve CLAIMED'
        reviews=session.scalars(select(AuditEvent).where(AuditEvent.reason_code=='ORDER_ATTRIBUTION_AMBIGUOUS')).all()
        assert {row.subject_id for row in reviews}=={'ambiguous-a','ambiguous-b'},'each refused attribution must be audited'
        settlements=session.scalars(select(WalletLedgerTransaction).where(WalletLedgerTransaction.scope=='wallet.manual_settle')).all()
        assert len(settlements)==1,'only unique payout may change the ledger'
        assert session.get(RedeemabilityReserve,'global').pending_payouts==3,'ambiguous and empty obligations remain'
    assert [ledger.balance('HOLD:'+uid) for uid in ('worker-a','worker-b','worker-c','worker-d')]==[
        Decimal('10'),Decimal('10'),Decimal('0'),Decimal('10')],'ambiguous/empty HOLD must not change'
    assert scans==[{'funds_enabled':False}] and run['receipts_credited']==0,'funding must remain disabled'
    assert len(requests)==3 and set(requests)==set(receipts),'empty locator must not call provider'
    return {'cases':dict(ambiguous_cross_user_receipt='PASS',unique_receipt='PASS',empty_candidate='PASS',funding_disabled='PASS')}


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--expected-sources',required=True)
    parser.add_argument('--installed',action='store_true')
    args=parser.parse_args()
    if args.installed:
        assert not os.environ.get('PYTHONPATH'),'PYTHONPATH may not mask installed Worker sources'
    expected=json.loads(Path(args.expected_sources).read_text(encoding='utf-8'))
    register_models()
    identity=source_identity(expected,args.installed)
    raw=os.environ.get('SUPPORT_WORKER_PROBE_DATABASE_URL','')
    url=make_url(raw)
    assert (url.host in ('127.0.0.1','localhost') and url.database in
        ('clone','support_payout_review','support_worker_review')),'dedicated localhost clone database required'
    schema='support_worker_probe_'+uuid4().hex
    admin=create_engine(url,isolation_level='AUTOCOMMIT')
    engine=None
    try:
        with admin.connect() as connection:
            version=connection.scalar(text('SELECT version_num FROM public.alembic_version'))
            assert version.startswith('0093'),'0093 clone migration required'
            connection.execute(text(f'CREATE SCHEMA "{schema}"'))
            tables=connection.scalars(text("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")).all()
            for name in tables:
                quoted=connection.dialect.identifier_preparer.quote(name)
                connection.execute(text(f'CREATE TABLE "{schema}".{quoted} (LIKE public.{quoted} INCLUDING ALL)'))
        engine=create_engine(url.update_query_dict({'options':'-csearch_path='+schema+' -clock_timeout=5000 -cstatement_timeout=60000'}))
        from app.core.database import create_session_factory
        result=run_cases(create_session_factory(engine))
        print(json.dumps({'status':'PASS','schema_migration':version,'sources':identity,**result},sort_keys=True))
    finally:
        if engine is not None:
            engine.dispose()
        with admin.connect() as connection:
            connection.execute(text(f'DROP SCHEMA IF EXISTS "{schema}" CASCADE'))
        admin.dispose()


if __name__=='__main__':
    main()
