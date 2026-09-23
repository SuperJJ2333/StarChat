"""Public wallet boundary for verified receipt reservation and CAIBI consumption."""
from dataclasses import asdict
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
from sqlalchemy import select
from app.core.errors import AppError
from app.integrations.tron.finality import TransactionEvidence, transaction_evidence_fresh, NETWORK, POLICY, SOURCE_ID
from app.integrations.tron.reader import USDT_CONTRACT
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.recharge_receipt_models import RechargeReceiptReservation
from app.modules.identity.models import User
from app.modules.identity.enums import AccountStatus
from app.modules.ledger.wallet_obligations import transfer_pending_to_credit
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.models import Deposit


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def fail(code):
    raise AppError(code=code,message='付款证据或归属需进一步核对',status_code=409)


def reserved_for_recharge(session,receipt_id):
    return session.get(RechargeReceiptReservation,receipt_id) is not None


def require_unambiguous_transaction(session, row):
    # Legacy deposits have no log index; no transfer in that transaction is safe
    # to consume again until an explicit reconciliation establishes its mapping.
    if (session.scalar(select(Deposit.id).where(Deposit.txid == row.txid)) is not None
            or session.scalar(select(DepositReceiptAnomaly.id).join(DepositReceipt,
                DepositReceipt.id == DepositReceiptAnomaly.receipt_id).where(
                    DepositReceipt.txid == row.txid)) is not None):
        fail('RECHARGE_EVIDENCE_CONFLICT')


class RechargeReceiptOperations:
    def recharge_evidence(self,txid):
        # Ingest only immutable facts; automatic credits MUST be deferred.
        self.ingest(txid,actor_id='support-receipt-verifier',defer_credit=True)
        proof=self.adapter.transaction_evidence(txid)
        if not isinstance(proof,TransactionEvidence) or proof.txid!=txid:
            fail('RECHARGE_EVIDENCE_INVALID')
        return proof

    def reserve_recharge_payment(self,session,*,request_id,user_id,official_payment,created_at,proof,log_index,actor_id,now):
        lock_budget(session)
        if not transaction_evidence_fresh(proof,now): fail('RECHARGE_EVIDENCE_EXPIRED')
        if (proof.network!=NETWORK or proof.contract!=USDT_CONTRACT or proof.policy!=POLICY or proof.source_id!=SOURCE_ID
            or proof.solid_head.network!=NETWORK or proof.solid_head.source_id!=SOURCE_ID or proof.solid_head.policy!=POLICY
            or proof.block_number>proof.solid_head.height): fail('RECHARGE_EVIDENCE_INVALID')
        row=session.scalar(select(DepositReceipt).where(DepositReceipt.txid==proof.txid,
            DepositReceipt.network==NETWORK,DepositReceipt.contract==USDT_CONTRACT,DepositReceipt.log_index==log_index).with_for_update())
        if row is None or row.status!='REVIEW' or not row.pending_obligation or row.amount is None or row.amount<=0:
            fail('RECHARGE_EVIDENCE_CONSUMED')
        require_unambiguous_transaction(session, row)
        if (row.official_address!=official_payment['address'] or row.official_config_version!=official_payment['config_version']
            or row.source_address==row.official_address or row.block_number<=self.activation_baseline_height
            or utc(row.block_time)<self.activation_baseline_time or utc(row.block_time)<utc(created_at)):
            fail('RECHARGE_PAYMENT_ATTRIBUTION_REQUIRED')
        transfers=[t for t in proof.transfers if t.log_index==log_index and t.contract==USDT_CONTRACT]
        if len(transfers)!=1: fail('RECHARGE_EVIDENCE_INVALID')
        t=transfers[0]
        facts={'transfer':asdict(t),'network':proof.network,'policy':proof.policy,'source':proof.source_id,
            'block':proof.block_id,'height':proof.block_number,'time':proof.timestamp_ms,'contract':proof.contract}
        digest=hashlib.sha256(json.dumps(facts,sort_keys=True).encode()).hexdigest()
        if (digest!=row.facts_digest or t.txid!=proof.txid or t.block_number!=proof.block_number
            or t.block_id!=proof.block_id or t.timestamp_ms!=proof.timestamp_ms
            or session.scalar(select(DepositReceiptAnomaly.id).where(DepositReceiptAnomaly.receipt_id==row.id))):
            fail('RECHARGE_EVIDENCE_CONFLICT')
        owner=session.get(WalletAddressOwner,row.source_address)
        bindings=list(session.scalars(select(WalletBinding).where(WalletBinding.address==row.source_address,
            WalletBinding.status.in_(['ACTIVE','RETIRED']),WalletBinding.effective_from_block<=row.block_number,
            (WalletBinding.effective_to_block.is_(None))|(WalletBinding.effective_to_block>row.block_number))))
        user=session.get(User,user_id)
        if (owner is None or owner.user_id!=user_id or len(bindings)!=1 or bindings[0].user_id!=user_id
            or user is None or user.status!=AccountStatus.ACTIVE): fail('RECHARGE_PAYMENT_ATTRIBUTION_REQUIRED')
        claim=session.get(RechargeReceiptReservation,row.id,with_for_update=True)
        other=session.scalar(select(RechargeReceiptReservation).where(RechargeReceiptReservation.request_id==request_id))
        if other is not None and other.receipt_id!=row.id: fail('RECHARGE_EVIDENCE_CONFLICT')
        if claim is not None and (claim.request_id!=request_id or claim.user_id!=user_id or claim.state!='RESERVED'):
            fail('RECHARGE_EVIDENCE_CONSUMED')
        if claim is None:
            claim=RechargeReceiptReservation(receipt_id=row.id,request_id=request_id,user_id=user_id,
                state='RESERVED',facts_digest=digest,verified_at=now,created_at=now)
            session.add(claim)
        else: claim.verified_at=now
        session.flush()
        return {'receipt_id':row.id,'amount_usdt':str(row.amount)}

    @staticmethod
    def require_recharge_reservation(session,*,request_id,receipt_id,user_id,now):
        lock_budget(session)
        row=session.get(DepositReceipt,receipt_id,with_for_update=True)
        claim=session.get(RechargeReceiptReservation,receipt_id,with_for_update=True)
        if (not row or not claim or claim.request_id!=request_id or claim.user_id!=user_id
            or claim.state!='RESERVED' or row.status!='REVIEW' or not row.pending_obligation
            or row.facts_digest!=claim.facts_digest): fail('RECHARGE_EVIDENCE_CONSUMED')
        if not 0 <= (now-utc(claim.verified_at)).total_seconds()<=120: fail('RECHARGE_EVIDENCE_EXPIRED')
        require_unambiguous_transaction(session, row)
        user = session.get(User, user_id)
        if user is None or user.status != AccountStatus.ACTIVE:
            fail('RECHARGE_PAYMENT_ATTRIBUTION_REQUIRED')
        return row,claim


def prepare_recharge_credit(session,*,request_id,receipt_id,user_id,now,reserve_policy,expected_amount=None):
    row,claim=RechargeReceiptOperations.require_recharge_reservation(session,
        request_id=request_id,receipt_id=receipt_id,user_id=user_id,now=now)
    if expected_amount is not None and row.amount != expected_amount:
        fail('RECHARGE_SETTLEMENT_MISMATCH')
    transfer_pending_to_credit(session,amount=row.amount,now=now,policy=reserve_policy)
    return row,claim


def complete_recharge_credit(session,*,prepared,ledger_transaction_id):
    row,claim=prepared
    claim.state='CONSUMED'
    claim.ledger_transaction_id=ledger_transaction_id
    session.flush([claim])
    row.status='CREDITED'
    row.pending_obligation=False
    row.user_id=claim.user_id
    row.recharge_request_id=claim.request_id
    row.caibi_ledger_transaction_id=ledger_transaction_id
    row.reason_code='SUPPORT_RECHARGE_SETTLED'
    session.flush()
