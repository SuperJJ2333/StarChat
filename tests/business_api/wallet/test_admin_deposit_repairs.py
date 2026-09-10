from importlib.util import find_spec

def test_manual_repair_application_service_exists():
    assert find_spec('app.modules.wallet.repairs') is not None, 'manual repair service missing'

from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
import pytest
from sqlalchemy import select, func
from app.core.errors import AppError
from app.modules.wallet.funding_models import DepositIntent
from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
from app.modules.wallet.safety import usdt_liability
from app.modules.identity.models import User, UserRole, AccountStatus
from app.modules.identity.enums import RoleCode
from test_deposit_receipts import core, intent, ingest  # noqa: F401

@pytest.fixture
def repair(core):
    from app.modules.wallet.repairs import DepositRepairService
    from app.modules.wallet.repair_models import RepairPreview, RepairCommand
    RepairPreview.__table__.create(core[1].kw['bind'], checkfirst=True)
    RepairCommand.__table__.create(core[1].kw['bind'], checkfirst=True)
    first=intent(core)
    with core[1].begin() as s:
        row=s.get(DepositIntent,first['id']); row.status='EXPIRED'; row.closed_at=core[5]
        s.get(WalletControl,'global').withdrawals_paused=False
        s.add(User(id='owner',username='owner',username_normalized='owner',email='o@example.test',email_normalized='o@example.test',password_hash='fixture',status=AccountStatus.ACTIVE,created_at=core[5],updated_at=core[5]))
        s.add(UserRole(id='owner-role',user_id='owner',role_code=RoleCode.SUPER_ADMIN,assigned_by='fixture',assigned_at=core[5]))
    receipt=ingest(core)[0]
    service=DepositRepairService(core[1],receipts=core[0],owner_admin_id='owner',clock_trusted=lambda:True)
    return service,receipt['id'],first['id']

def preview(repair):
    svc,rid,iid=repair
    return svc.preview(actor_id='owner',receipt_id=rid,intent_id=iid,reason_code='EXPIRED_INTENT_REVIEW',reason_detail='核实历史绑定与固化交易',authorize=lambda s:lambda:None)

def execute(repair,p,key='one',operation='operation-one',authorize=lambda s:lambda:None):
    return repair[0].execute(actor_id='owner',preview_id=p['preview_id'],digest=p['digest'],expected_version=1,operation_id=operation,idempotency_key=key,authorize=authorize)

def test_expired_repair_preserves_original_facts_and_liability(core,repair):
    p=preview(repair)
    assert p['blockers']==[]
    result=execute(repair,p)
    assert result['status']=='EXECUTED'
    assert execute(repair,p)==result
    with core[1]() as s:
        original=s.get(DepositIntent,repair[2]); receipt=s.get(core[4],repair[1])
        assert original.status=='EXPIRED'
        assert receipt.reason_code=='INTENT_EXPIRED'
        assert receipt.status=='CREDITED' and not receipt.pending_obligation
        assert usdt_liability(s)==Decimal('10')
        assert s.scalar(select(func.count()).select_from(WalletLedgerTransaction))==1
    assert core[0].wallet_ledger.balance('alice')==Decimal('10')
    assert repair[0].status(actor_id='owner',operation_id='operation-one',authorize=lambda s:lambda:None)==result

def test_changed_idempotent_payload_is_conflict(core,repair):
    p=preview(repair); execute(repair,p)
    with pytest.raises(AppError) as exc: execute(repair,p,operation='another')
    assert exc.value.code=='IDEMPOTENCY_CONFLICT'

@pytest.mark.parametrize('failure',['clock','proof','authorization'])
def test_late_failure_rolls_back_credit(core,repair,failure):
    p=preview(repair)
    if failure=='clock': repair[0].clock_trusted=lambda:False
    if failure=='proof': core[2].value=replace(core[2].value,observed_at=core[5]-timedelta(minutes=10))
    calls=[]
    def authorize(s):
        def fresh():
            calls.append(1)
            if failure=='authorization' and len(calls)>1: raise AppError(code='WALLET_VERIFICATION_EXPIRED',message='expired',status_code=403)
        return fresh
    with pytest.raises(AppError): execute(repair,p,authorize=authorize)
    with core[1]() as s:
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.get(core[4],repair[1]).pending_obligation

def test_expired_preview_refused(core,repair):
    p=preview(repair)
    repair[0].clock=lambda:core[5]+timedelta(minutes=10)
    with pytest.raises(AppError) as exc: execute(repair,p)
    assert exc.value.code=='EVIDENCE_EXPIRED'


@pytest.mark.parametrize('delta,attested,allowed',[(30,True,True),(300,True,True),(301,True,False),(30,False,False)])
def test_preorder_manual_exception_is_bounded_attested(core,delta,attested,allowed):
    from app.modules.wallet.repairs import DepositRepairService
    # Reuse fixture construction, but construct immutable intent with a genuine later clock.
    core[3].clock=lambda:core[5].fromtimestamp(core[2].value.timestamp_ms/1000,core[5].tzinfo)+timedelta(seconds=delta)
    generator=repair.__wrapped__(core)
    svc,rid,iid=generator
    from app.modules.ledger.reserve import RedeemabilityReserve
    current=core[3].clock()+timedelta(seconds=5)
    svc.clock=lambda:current
    core[2].value=replace(core[2].value,observed_at=current,
        solid_head=replace(core[2].value.solid_head,observed_at=current,timestamp_ms=int(current.timestamp()*1000)))
    with core[1].begin() as s:
        s.get(RedeemabilityReserve,'global').observed_at=current
    p=svc.preview(actor_id='owner',receipt_id=rid,intent_id=iid,reason_code='PAYMENT_BEFORE_ORDER',
        reason_detail='核实该用户本次充值与所选订单关联',payment_attestation=attested,authorize=lambda s:lambda:None)
    assert (not p['blockers'])==allowed
    if allowed:
        assert execute(generator,p)['status']=='EXECUTED'
        with core[1]() as s:
            assert s.get(DepositIntent,iid).status=='EXPIRED'
            assert s.get(core[4],rid).reason_code=='NO_UNIQUE_INTENT'


@pytest.mark.parametrize('failure',['final_grant','audit'])
def test_final_commit_checks_rollback_all_money_and_commands(core,repair,monkeypatch,failure):
    from app.modules.wallet import repairs
    from app.modules.wallet.repair_models import RepairCommand
    p=preview(repair)
    calls=[]
    def authorize(s):
        def fresh():
            calls.append(1)
            if failure=='final_grant' and len(calls)==4:
                raise AppError(code='WALLET_VERIFICATION_EXPIRED',message='expired',status_code=403)
        return fresh
    if failure=='audit':
        def broken(*args): raise RuntimeError('audit unavailable')
        monkeypatch.setattr(repairs,'audit_write',broken)
    with pytest.raises((AppError,RuntimeError)): execute(repair,p,authorize=authorize)
    with core[1]() as s:
        assert s.scalar(select(RepairCommand)) is None
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.get(core[4],repair[1]).pending_obligation
        assert usdt_liability(s)==Decimal('10')

@pytest.mark.parametrize('problem,code',[('paused','FUNDS_CONTROL_BLOCKED'),('user','USER_UNAVAILABLE'),('evidence','EVIDENCE_CONFLICT'),('reserve','RESERVE_UNAVAILABLE')])
def test_preview_explains_current_blockers(core,repair,problem,code):
    from app.modules.ledger.reserve import RedeemabilityReserve
    from app.modules.identity.enums import AccountStatus
    if problem=='evidence':
        transfer=core[2].value.transfers[0]
        core[2].value=replace(core[2].value,transfers=(replace(transfer,amount_units=11000000),))
    else:
        with core[1].begin() as s:
            if problem=='paused': s.get(WalletControl,'global').withdrawals_paused=True
            if problem=='user': s.get(User,'alice').status=AccountStatus.DISABLED
            if problem=='reserve': s.get(RedeemabilityReserve,'global').observed_at=core[5]-timedelta(minutes=10)
    assert code in preview(repair)['blockers']


def test_foreign_actor_cannot_read_or_execute_case(core,repair):
    p=preview(repair)
    with pytest.raises(AppError) as exc:
        repair[0].execute(actor_id='alice',preview_id=p['preview_id'],digest=p['digest'],expected_version=1,
            operation_id='foreign',idempotency_key='foreign',authorize=lambda s:lambda:None)
    assert exc.value.code=='PERMISSION_DENIED'


def test_candidates_include_original_user_binding_and_amount(core,repair):
    result=repair[0].candidates(actor_id='owner',txid=core[2].value.txid,log_index=0,query='alice',authorize=lambda s:lambda:None)
    item=result['items'][0]
    assert item['username']=='alice' and item['intent_status']=='EXPIRED'
    assert item['binding_version']==1 and item['amount']=='10.000000'
    assert item['effective_from_block']==101
    assert result['reasons']['PAYMENT_BEFORE_ORDER']=='先付款后下单人工确认'

def test_deposit_endpoint_never_replays_a_payout_command(core,repair):
    from app.modules.wallet.repair_models import RepairCommand
    from app.modules.wallet.repairs import digest
    p=preview(repair)
    with core[1].begin() as s:
        s.add(RepairCommand(operation_id='operation-one',actor_id='owner',idempotency_key='one',
            payload_digest=digest(dict(preview_id=p['preview_id'],digest=p['digest'],expected_version=1,operation_id='operation-one')),
            preview_id=p['preview_id'],result={'status':'SUBMITTED'},created_at=core[5]))
    with pytest.raises(AppError) as exc: execute(repair,p)
    assert exc.value.code=='IDEMPOTENCY_CONFLICT'
