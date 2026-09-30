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


def test_recharge_claim_version_advances_only_when_lease_changes(flow):
    service,clock,factory=flow; order=submit(service)
    assert order['claim_version']==0
    first=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='claim-1')
    assert first['claim_version']==1
    replay=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='claim-1')
    assert replay['claim_version']==1
    service.heartbeat_order(request_id=order['id'],actor_id='cs1',claim_token=first['claim_token'])
    assert service.admin_requests(status='SUBMITTED')['items'][0]['claim_version']==1
    clock[0]+=timedelta(minutes=6)
    second=service.claim_order(request_id=order['id'],actor_id='cs2',idempotency_key='claim-2')
    assert second['claim_version']==2
    with factory() as session:
        from app.modules.recharge.models import RechargeRequest
        assert session.get(RechargeRequest,order['id']).claim_version==2


def test_recharge_list_capabilities_follow_current_actor_and_configured_owner(flow):
    from uuid import uuid4
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole
    service,_,factory=flow; order=submit(service)
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',
            password_hash='unused',status=AccountStatus.ACTIVE,
            created_at=service._utcnow(),updated_at=service._utcnow()))
        session.add(UserRole(id=str(uuid4()),user_id='owner',role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner',assigned_at=service._utcnow()))
        session.add(UserRole(id=str(uuid4()),user_id='cs2',role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner',assigned_at=service._utcnow()))

    def view(actor):
        return service.pending_page(actor_id=actor,owner_id='owner')['items'][0]

    assert view('cs2')['can_claim'] is True
    first=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='owned')
    other=view('cs2')
    assert other['claimed_by']=='cs1'
    assert other['can_claim'] is False and other['can_takeover'] is False
    assert other['can_process'] is False and other['takeover_review_required'] is False
    assert view('cs1')['can_process'] is True
    assert view('owner')['can_takeover'] is True

    with factory.begin() as session:
        session.query(UserRole).filter_by(user_id='owner').delete()
    assert view('owner')['can_takeover'] is False

    service.submit_evidence(request_id=order['id'],user_id='alice',txid='a'*64,idempotency_key='evidence')
    assert view('cs2')['can_claim'] is False
    assert view('cs2')['takeover_review_required'] is True
    service.heartbeat_order(request_id=order['id'],actor_id='cs1',claim_token=first['claim_token'])


def test_user_provided_txid_still_allows_first_staff_claim(flow):
    service,clock,_=flow
    order=service.submit(user_id='alice',amount_usdt=Decimal('10'),
        evidence_txid='b'*64,idempotency_key='submitted-with-evidence')
    projection=service.pending_page(actor_id='cs1',owner_id='owner')['items'][0]
    assert projection['id']==order['id']
    assert projection['can_claim'] is True
    claim=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='first-claim')
    assert claim['claimed_by']=='cs1'
    clock[0]+=timedelta(minutes=6)
    assert service.pending_page(actor_id='cs1',owner_id='owner')['items'][0]['can_claim'] is True
    assert service.pending_page(actor_id='cs2',owner_id='owner')['items'][0]['can_claim'] is False
    with pytest.raises(AppError) as occupied:
        service.claim_order(request_id=order['id'],actor_id='cs2',idempotency_key='unsafe-evidence-steal')
    assert occupied.value.code=='RECHARGE_TAKEOVER_REQUIRED'
    renewed=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='renew-own-claim')
    assert renewed['claim_version']==claim['claim_version']+1


@pytest.mark.parametrize('expired_with_evidence', [False, True])
def test_only_configured_owner_with_fresh_proof_can_take_over_active_recharge_lease(flow,expired_with_evidence):
    from uuid import uuid4
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole
    service,clock,factory=flow; order=submit(service)
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',
            password_hash='unused',status=AccountStatus.ACTIVE,
            created_at=service._utcnow(),updated_at=service._utcnow()))
        session.add(UserRole(id=str(uuid4()),user_id='owner',role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner',assigned_at=service._utcnow()))
    first=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='claim')
    if expired_with_evidence:
        service.submit_evidence(request_id=order['id'],user_id='alice',
            txid='a'*64,idempotency_key='evidence-before-expiry')
        clock[0]+=timedelta(minutes=6)
        owner_view=service.pending_page(actor_id='owner',owner_id='owner')['items'][0]
        assert owner_view['can_takeover'] is True
        assert owner_view['takeover_review_required'] is True
    authorization=lambda session: lambda: None
    command=dict(request_id=order['id'],actor_id='owner',owner_id='owner',
        expected_claim_version=first['claim_version'],reason_code='RECHARGE_STAFF_UNAVAILABLE',
        idempotency_key='owner-takeover',authorization=authorization,
        owner_authorization=authorization)
    with pytest.raises(AppError) as denied:
        service.takeover_order(**{**command,'actor_id':'cs2'})
    assert denied.value.status_code==403
    with pytest.raises(AppError) as denied:
        service.takeover_order(**{**command,'owner_authorization':None})
    assert denied.value.status_code==403
    result=service.takeover_order(**command)
    assert result['claimed_by']=='owner' and result['claim_version']==first['claim_version']+1
    assert result['claim_token']!=first['claim_token']
    assert service.takeover_order(**command)['claim_token']==result['claim_token']
    with pytest.raises(AppError) as stale:
        service.heartbeat_order(request_id=order['id'],actor_id='cs1',claim_token=first['claim_token'])
    assert stale.value.code=='RECHARGE_CLAIM_LOST'
    assert service.heartbeat_order(request_id=order['id'],actor_id='owner',
        claim_token=result['claim_token'])['claim_version']==result['claim_version']
    with pytest.raises(AppError):
        service.takeover_order(**{**command,'idempotency_key':'stale-key'})


@pytest.mark.parametrize('has_receipt,beneficiary,adjustment_status,binding_state', [
    (False,'alice','SUBMITTED','BOUND'),
    (True,'bob','SUBMITTED','BOUND'),
    (True,'alice','EXECUTED','BOUND'),
    (True,'alice','SUBMITTED','NEEDS_REVIEW'),
])
def test_recharge_takeover_does_not_transfer_unattributed_binding(
        flow,has_receipt,beneficiary,adjustment_status,binding_state):
    from uuid import uuid4
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole
    from app.modules.recharge.models import RechargeRequest, RechargeCreditBinding
    from app.modules.ledger.adjustment_models import AdjustmentRequest
    service,_,factory=flow; order=submit(service)
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',
            password_hash='unused',status=AccountStatus.ACTIVE,
            created_at=service._utcnow(),updated_at=service._utcnow()))
        session.add(UserRole(id=str(uuid4()),user_id='owner',role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner',assigned_at=service._utcnow()))
    original=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='claim-bound')
    with factory.begin() as session:
        row=session.get(RechargeRequest,order['id'])
        if has_receipt:
            row.receipt_id='receipt-isolated'
            row.evidence_txid='a'*64
            row.payment_verified_at=service._utcnow()
            row.actual_received_usdt=Decimal('10')
        session.add(AdjustmentRequest(id='adjustment-isolated',user_id=beneficiary,
            amount=Decimal('10.00'),reason_code='RECHARGE_CREDIT',status=adjustment_status,
            submitted_by='cs1',idempotency_key='bound-adjustment',
            business_date=service._utcnow().date(),created_at=service._utcnow(),
            updated_at=service._utcnow()))
        session.add(RechargeCreditBinding(id='binding-isolated',request_id=order['id'],
            adjustment_id='adjustment-isolated',state=binding_state,state_active='1',
            bound_by='cs1',created_at=service._utcnow(),updated_at=service._utcnow()))
    if has_receipt:
        service.wallet_receipts=SimpleNamespace(require_recharge_handoff_reservation=lambda *args,**kwargs:
            (SimpleNamespace(amount=Decimal('10'),txid='a'*64,
                official_address='official-test-address',official_config_version='v1'),
             SimpleNamespace(state='RESERVED')))
    assert service.pending_page(actor_id='owner',owner_id='owner')['items'][0]['can_takeover'] is False
    authorization=lambda session: lambda: None
    with pytest.raises(AppError) as denied:
        service.takeover_order(request_id=order['id'],actor_id='owner',owner_id='owner',
            expected_claim_version=original['claim_version'],reason_code='RECHARGE_INCIDENT_REVIEW',
            idempotency_key='reject-inconsistent-binding',authorization=authorization,
            owner_authorization=authorization)
    assert denied.value.code=='RECHARGE_TAKEOVER_REVIEW_REQUIRED'
    with factory() as session:
        assert session.get(RechargeRequest,order['id']).claimed_by=='cs1'


@pytest.mark.parametrize('order_expired', [False, True])
def test_owner_takeover_preserves_old_receipt_and_active_unexecuted_binding(flow,order_expired):
    from uuid import uuid4
    from app.modules.identity.enums import RoleCode
    from app.modules.identity.models import UserRole
    from app.modules.recharge.models import RechargeRequest, RechargeCreditBinding
    from app.modules.ledger.adjustment_models import AdjustmentRequest
    service,clock,factory=flow; order=submit(service)
    with factory.begin() as session:
        session.add(User(id='owner',username='owner',username_normalized='owner',
            password_hash='unused',status=AccountStatus.ACTIVE,
            created_at=service._utcnow(),updated_at=service._utcnow()))
        session.add(UserRole(id=str(uuid4()),user_id='owner',role_code=RoleCode.SUPER_ADMIN,
            assigned_by='owner',assigned_at=service._utcnow()))
    original=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='claim-safe')
    with factory.begin() as session:
        row=session.get(RechargeRequest,order['id'])
        row.receipt_id='receipt-safe'
        row.evidence_txid='a'*64
        row.payment_verified_at=clock[0]
        row.actual_received_usdt=Decimal('10')
        row.processing_stage='PAYMENT_VERIFIED'
        session.add(AdjustmentRequest(id='adjustment-safe',user_id='alice',
            amount=Decimal('70.00'),reason_code='RECHARGE_CREDIT',status='SUBMITTED',
            submitted_by='cs1',idempotency_key='safe-adjustment',
            business_date=clock[0].date(),created_at=clock[0],updated_at=clock[0]))
        session.add(RechargeCreditBinding(id='binding-safe',request_id=order['id'],
            adjustment_id='adjustment-safe',state='BOUND',state_active='1',
            final_caibi_amount=Decimal('70.00'),bound_by='cs1',
            created_at=clock[0],updated_at=clock[0]))
    clock[0]+=timedelta(hours=3) if order_expired else timedelta(minutes=3)
    def stale_settlement(*args,**kwargs):
        raise AppError(code='RECHARGE_EVIDENCE_EXPIRED',message='stale',status_code=409)
    service.wallet_receipts=SimpleNamespace(require_recharge_reservation=stale_settlement,
        preview_recharge_handoff_reservation=lambda *args,**kwargs: None,
        require_recharge_handoff_reservation=lambda *args,**kwargs:
            (SimpleNamespace(amount=Decimal('10'),txid='a'*64,
                official_address='official-test-address',official_config_version='v1'),
             SimpleNamespace(state='RESERVED')))
    assert service.pending_page(actor_id='owner',owner_id='owner')['items'][0]['can_takeover'] is False
    service.wallet_receipts.preview_recharge_handoff_reservation=(lambda *args,**kwargs:
        SimpleNamespace(amount=Decimal('10'),txid='a'*64,
            official_address='official-test-address',official_config_version='v1'))
    owner_view=service.pending_page(actor_id='owner',owner_id='owner')['items'][0]
    assert owner_view['can_takeover'] is True
    assert owner_view['takeover_review_required'] is True
    authorization=lambda session: lambda: None
    moved=service.takeover_order(request_id=order['id'],actor_id='owner',owner_id='owner',
        expected_claim_version=original['claim_version'],reason_code='RECHARGE_SHIFT_HANDOFF',
        idempotency_key='takeover-safe',authorization=authorization,
        owner_authorization=authorization)
    assert moved['evidence_txid']=='a'*64
    assert moved['payment_verified'] is True
    assert moved['claim_version']==original['claim_version']+1
    assert service.heartbeat_order(request_id=order['id'],actor_id='owner',
        claim_token=moved['claim_token'])['claim_version']==moved['claim_version']
    with pytest.raises(AppError) as stale:
        service.heartbeat_order(request_id=order['id'],actor_id='cs1',
            claim_token=original['claim_token'])
    assert stale.value.code=='RECHARGE_CLAIM_LOST'
    with factory() as session:
        row=session.get(RechargeRequest,order['id'])
        binding=session.get(RechargeCreditBinding,'binding-safe')
        assert row.receipt_id=='receipt-safe' and row.actual_received_usdt==Decimal('10')
        assert binding.state=='BOUND' and binding.adjustment_id=='adjustment-safe'


def test_same_claimant_can_enter_expired_receipt_review_without_erasing_proof(flow):
    from app.modules.recharge.models import RechargeRequest
    service,clock,factory=flow; order=submit(service)
    initial=service.claim_order(request_id=order['id'],actor_id='cs1',idempotency_key='initial')
    with factory.begin() as session:
        row=session.get(RechargeRequest,order['id'])
        row.receipt_id='receipt-old'
        row.evidence_txid='a'*64
        row.payment_verified_at=clock[0]
        row.actual_received_usdt=Decimal('10')
        row.processing_stage='PAYMENT_VERIFIED'
    clock[0]+=timedelta(hours=3)
    service.wallet_receipts=SimpleNamespace(require_recharge_handoff_reservation=lambda *args,**kwargs:
        (SimpleNamespace(amount=Decimal('10'),txid='a'*64,
            official_address='official-test-address',official_config_version='v1'),
         SimpleNamespace(state='RESERVED')))
    renewed=service.claim_order(request_id=order['id'],actor_id='cs1',
        idempotency_key='review-own-proof',review=True,reason='继续核对已到账凭证')
    assert renewed['payment_verified'] is True
    assert renewed['claim_version']==initial['claim_version']+1
    service.heartbeat_order(request_id=order['id'],actor_id='cs1',claim_token=renewed['claim_token'])
    with factory() as session:
        row=session.get(RechargeRequest,order['id'])
        assert row.receipt_id=='receipt-old' and row.payment_verified_at is not None

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
