"""The published legacy UNKNOWN void remains terminal under support recovery."""
from datetime import timedelta,timezone
from decimal import Decimal

import pytest
from app.core.errors import AppError
from app.modules.wallet.manual_payout_models import ManualPayoutOrder
from test_manual_payouts import core,request
from test_support_payout import scoped


def void_legacy_unknown(scoped,*,takeover=False):
    core,support,claims=scoped
    order=request(core)
    lease=support.claim(claims=claims['bob'],order_id=order['id'],idempotency_key='void-lease')
    support.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=order['digest'],idempotency_key='void-begin')
    owner_token=None
    if takeover:
        owner_token=support.takeover(claims=claims['owner'],order_id=order['id'],expected_claim_version=1,
            reason_code='SUPPORT_OWNER_RECOVERY',idempotency_key='void-takeover',
            owner_authorize=lambda session:lambda:None)['evidence_token']
    # This is an existing legacy UNKNOWN fact; empty reconcile remains CLAIMED.
    assert core[0].reconcile(order_id=order['id'])['status']=='CLAIMED'
    with core[1].begin() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        row.status='UNKNOWN'
    with core[1]() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        version=getattr(row,'version',1)
        claim_ms=int(row.claimed_at.replace(tzinfo=timezone.utc).timestamp()*1000)
    now=core[2][0]
    evidence=dict(source_id='synthetic-observer',observation_id='synthetic-void',checkpoint=int(now.timestamp()*1000),
        observed_at=now,scanned_from=claim_ms,reconciliation_status='SOURCE_MATCHED',matching_outflows=0,
        suspicious_outflows=0,fresh_until_ms=int((now+timedelta(seconds=60)).timestamp()*1000),max_rowid=1)
    result=core[0].void_unbroadcast(admin_id='owner',order_id=order['id'],expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED',never_signed=True,never_broadcast=True,
        idempotency_key='void-command',evidence=evidence,authorize=lambda session:lambda:None,
        verify_evidence=lambda session,evidence:True)
    assert result['status']=='VOIDED' and result['processing_stage']=='VOIDED'
    assert core[5].balance('HOLD:alice')==Decimal('0')
    return order,lease,owner_token


def test_published_void_preserves_payer_and_revokes_all_support_capabilities(scoped):
    core,support,claims=scoped
    order,lease,owner_token=void_legacy_unknown(scoped,takeover=True)
    for actor in ('bob','owner'):
        view=support.detail(claims=claims[actor],order_id=order['id'])
        assert view['processing_stage']=='VOIDED'
        assert not any(view[key] for key in ('can_claim','can_begin','can_evidence','can_takeover'))
        assert 'claim_token' not in view
    with core[1]() as session:
        assert session.get(ManualPayoutOrder,order['id']).claimed_by=='bob'
    with pytest.raises(AppError):
        support.takeover_receipt(claims=claims['owner'],order_id=order['id'],expected_claim_version=1,
            reason_code='SUPPORT_OWNER_RECOVERY',idempotency_key='void-takeover')
    for actor,token in [('bob',lease['claim_token']),('owner',owner_token)]:
        with pytest.raises(AppError):
            support.submit_txid(claims=claims[actor],order_id=order['id'],claim_token=token,
                txid='a'*64,idempotency_key='void-txid-'+actor)
        with pytest.raises(AppError):
            support.read_payment_address(claims=claims[actor],order_id=order['id'],claim_token=token)
        with pytest.raises(AppError):
            support.discover(claims=claims[actor],order_id=order['id'],claim_token=token)
        with pytest.raises(AppError):
            support.reconcile(claims=claims[actor],order_id=order['id'],claim_token=token)
    core[2][0]+=timedelta(hours=3)
    assert support.expire_orders()==0
    assert core[0].reconcile(order_id=order['id'])['status']=='VOIDED'


def test_void_after_rate_preparation_reverses_original_conversion_as_actual_owner(scoped):
    from sqlalchemy import select
    from app.modules.wallet.models import WalletConversion, WalletLedgerTransaction
    from app.modules.ledger.service import LedgerService
    from app.modules.ledger.models import LedgerTransaction
    from test_support_payout import caibi_order, prepare
    core, support, claims=scoped
    order,lease=caibi_order(scoped)
    prepared=prepare(scoped,order,lease,rate='7.500000',version=0,key='void-rate')
    support.begin_payment(claims=claims['bob'],order_id=order['id'],claim_token=lease['claim_token'],
        expected_digest=prepared['prepared_digest'],expected_preparation_version=1,idempotency_key='void-rate-begin')
    with core[1].begin() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        row.status='UNKNOWN'
    with core[1]() as session:
        row=session.get(ManualPayoutOrder,order['id'])
        version=row.version
        claim_ms=int(row.claimed_at.replace(tzinfo=timezone.utc).timestamp()*1000)
        original=session.scalar(select(WalletConversion).where(WalletConversion.idempotency_key=='payout:'+order['id']))
        original_id=original.id
    now=core[2][0]
    proof=dict(source_id='synthetic-observer',observation_id='rate-void',checkpoint=int(now.timestamp()*1000),
        observed_at=now,scanned_from=claim_ms,reconciliation_status='SOURCE_MATCHED',matching_outflows=0,
        suspicious_outflows=0,fresh_until_ms=int((now+timedelta(seconds=60)).timestamp()*1000),max_rowid=1)
    args=dict(admin_id='owner',order_id=order['id'],expected_version=version,
        reason_code='NEVER_BROADCAST_CONFIRMED',never_signed=True,never_broadcast=True,
        idempotency_key='rate-void-command',evidence=proof,authorize=lambda session:lambda:None,
        verify_evidence=lambda session,evidence:True)
    result=core[0].void_unbroadcast(**args)
    assert core[0].void_unbroadcast(**args)==result
    assert core[5].balance('HOLD:alice')==0
    assert core[5].balance('alice')==Decimal('1000')
    assert LedgerService(core[1]).balance('alice')==Decimal('300.00')
    with core[1]() as session:
        reversal=session.scalar(select(WalletConversion).where(WalletConversion.idempotency_key=='reverse:'+original_id))
        assert reversal.source_amount==Decimal('20') and reversal.target_amount==Decimal('142.40')
        releases=session.scalars(select(WalletLedgerTransaction).where(
            WalletLedgerTransaction.reason_code=='MANUAL_PAYOUT_VOIDED')).all()
        assert len(releases)==2 and all(row.actor_id=='owner' for row in releases)
        caibi=session.scalar(select(LedgerTransaction).where(LedgerTransaction.reason_code=='MANUAL_PAYOUT_VOIDED'))
        assert caibi.actor_id=='owner' and caibi.reversal_of_id is not None
