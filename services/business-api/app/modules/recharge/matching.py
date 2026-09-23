"""Match trusted observer receipts to bound-wallet orders, without crediting."""
from decimal import Decimal
from sqlalchemy import select
from app.core.errors import AppError
from app.modules.ledger.reserve import lock_budget
from app.modules.recharge.models import RechargeRequest
from app.modules.recharge.models import RechargeCreditBinding
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.integrations.tron.finality import TronEvidenceUnavailable
from app.modules.recharge.workflow import utc

ACTOR='recharge-observer-worker'


class AutomaticRechargeMatching:
    def _matching_orders(self, session, candidate):
        # Include cancelled/unresolved orders: a second request must not steal
        # a transfer merely because its first order was cancelled on the phone.
        return list(session.scalars(select(RechargeRequest).where(
            RechargeRequest.user_id==candidate['user_id'],RechargeRequest.expires_at.is_not(None),
            RechargeRequest.created_at<=candidate['block_time'],RechargeRequest.expires_at>=candidate['block_time'],
            RechargeRequest.receipt_id.is_(None))
            .order_by(RechargeRequest.created_at,RechargeRequest.id).with_for_update()))

    def _review_matches(self, session, rows):
        count=0
        for row in rows:
            if row.status=='SUBMITTED' and row.processing_stage!='NEEDS_REVIEW':
                row.processing_stage='NEEDS_REVIEW'
                self._order_event(session,row,ACTOR,'recharge.payment_match_review')
                count+=1
        return count

    def reconcile_observed_payments(self, *, limit=50):
        result={'matched':0,'review':0,'errors':0}
        if self.wallet_receipts is None:return result
        candidates=self.wallet_receipts.observed_recharge_candidates(
            after=getattr(self,'_matching_after',None),limit=limit)
        self._matching_after=candidates[-1]['receipt_id'] if len(candidates)==limit else None
        for candidate in candidates:
            try:
                # Cheap domain eligibility before fresh network validation.
                with self.factory.begin() as session:
                    lock_budget(session)
                    rows=self._matching_orders(session,candidate)
                    exact=[r for r in rows if r.amount_usdt==Decimal(candidate['amount_usdt'])]
                    if len(exact)!=1:
                        result['review']+=self._review_matches(session,exact or rows)
                        continue
                    row=exact[0]
                    if (row.status!='SUBMITTED' or self._processing_stage(row)=='NEEDS_REVIEW'
                            or utc(row.expires_at)<candidate['block_time']):
                        result['review']+=self._review_matches(session,[row]);continue
                    request_id=row.id
                proof=self.wallet_receipts.recharge_evidence(candidate['txid'])
                with self.factory.begin() as session:
                    lock_budget(session)
                    rows=self._matching_orders(session,candidate)
                    exact=[r for r in rows if r.amount_usdt==Decimal(candidate['amount_usdt'])]
                    if len(exact)!=1 or exact[0].id!=request_id:
                        result['review']+=self._review_matches(session,exact or rows);continue
                    row=exact[0]
                    if (row.status!='SUBMITTED' or self._processing_stage(row)=='NEEDS_REVIEW'
                            or utc(row.expires_at)<candidate['block_time']):
                        result['review']+=self._review_matches(session,[row]);continue
                    if row.evidence_txid and row.evidence_txid!=candidate['txid']:
                        result['review']+=self._review_matches(session,[row]);continue
                    owner=self._claim(session,scope='recharge.evidence_transaction',key=candidate['txid'],
                        payload={'request_id':row.id},conflict_code='RECHARGE_EVIDENCE_REUSED')
                    payment=self.wallet_receipts.reserve_recharge_payment(session,request_id=row.id,
                        user_id=row.user_id,official_payment=row.official_payment,created_at=row.created_at,
                        proof=proof,log_index=candidate['log_index'],actor_id=ACTOR,now=self._utcnow())
                    self._complete(owner,{'request_id':row.id})
                    row.receipt_id=payment['receipt_id'];row.evidence_txid=candidate['txid']
                    row.actual_received_usdt=Decimal(payment['amount_usdt'])
                    row.payment_verified_at=self._utcnow();row.processing_stage='PAYMENT_VERIFIED'
                    self._order_event(session,row,ACTOR,'recharge.payment_verified')
                    result['matched']+=1
            except (AppError, TronEvidenceUnavailable):
                # No inferred success; immutable observer receipts remain for
                # next scan or manual review, and no financial entry is made.
                result['errors']+=1
        return result

    def refresh_detected_payment(self, *, request_id, actor_id, claim_token, authorization=None):
        with self._authorized_transaction(authorization) as session:
            row=session.get(RechargeRequest,request_id)
            if row is None or row.status=='CREDITED' or row.expires_at is None:return
            self._require_claim(row,actor_id,claim_token,allow_review=True)
            executed=session.scalar(select(AdjustmentRequest.id).join(RechargeCreditBinding,
                RechargeCreditBinding.adjustment_id==AdjustmentRequest.id).where(
                    RechargeCreditBinding.request_id==row.id,
                    RechargeCreditBinding.state_active=='1',AdjustmentRequest.status=='EXECUTED'))
            # Execution has already consumed the receipt. Registration verifies
            # that immutable ledger/receipt relationship and must not re-reserve.
            if executed is not None:return
            if not row.receipt_id or row.payment_verified_at is None:return
            if (self._utcnow()-utc(row.payment_verified_at)).total_seconds()<90:return
            reference=self.wallet_receipts.recharge_payment_reference(receipt_id=row.receipt_id,
                request_id=row.id,user_id=row.user_id)
        from uuid import uuid4
        self.verify_order_payment(request_id=request_id,actor_id=actor_id,claim_token=claim_token,
            **reference,idempotency_key='refresh:'+str(uuid4()),authorization=authorization)
