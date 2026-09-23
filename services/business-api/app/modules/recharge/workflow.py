"""Durable support ownership; deadlines and estimates never authorize money."""
from datetime import timedelta, timezone
from decimal import Decimal
import hashlib
import re
import secrets
from uuid import uuid4
from contextlib import contextmanager, nullcontext
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.recharge.models import RechargeRequest, RechargeCreditBinding


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def fail(code, message, status=409):
    raise AppError(code=code, message=message, status_code=status)


class SupportOrderWorkflow:
    def _require_settlement_enabled(self):
        if getattr(self, 'settlement_enabled', True) is not True:
            fail('RECHARGE_SETTLEMENT_DISABLED', '人工充值暂不可用，请勿付款', 503)

    @contextmanager
    def _authorized_transaction(self, authorization=None, session=None):
        with (self.factory.begin() if session is None else nullcontext(session)) as session:
            fresh = authorization(session) if authorization else None
            yield session
            if fresh:
                fresh()

    def official_payment_view(self):
        self._require_settlement_enabled()
        config = self.official_config
        if config is None:
            fail('RECHARGE_OFFICIAL_PAYMENT_UNAVAILABLE', '官方收款信息暂不可用', 503)
        return {'network': 'TRON', 'address': config.address, 'config_version': config.version}

    def _processing_stage(self, row):
        if row.status != 'SUBMITTED':
            return row.status
        if row.expires_at and utc(row.expires_at) <= self._utcnow() and not row.review_authorized_at:
            return 'NEEDS_REVIEW'
        return row.processing_stage or 'SUBMITTED'

    def _order(self, session, request_id):
        row = session.get(RechargeRequest, request_id, with_for_update=True)
        if row is None:
            fail('RECHARGE_NOT_FOUND', '充值申请不存在', 404)
        return row

    def _order_event(self, session, row, actor_id, event_type):
        now = self._utcnow()
        session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='recharge_request',
            subject_id=row.id, action=event_type, result='SUCCESS', reason_code=event_type.upper().replace('.', '_'),
            trace_id=row.id[:32], created_at=now))
        OutboxPublisher.enqueue(session, topic='recharge', event_type=event_type,
            aggregate_type='recharge_request', aggregate_id=row.id,
            payload={'request_id': row.id, 'status': row.status, 'processing_stage': self._processing_stage(row)}, now=now)
        row.updated_at = now

    def _require_claim(self, row, actor_id, claim_token, *, allow_review=False):
        if row.expires_at is None:  # historical finance cases retain their existing review flow
            return
        token_hash = hashlib.sha256((claim_token or '').encode()).hexdigest()
        if (row.claimed_by != actor_id or not row.claim_token_hash
                or not secrets.compare_digest(row.claim_token_hash, token_hash)
                or row.claim_expires_at is None or utc(row.claim_expires_at) <= self._utcnow()):
            fail('RECHARGE_CLAIM_LOST', '认领已失效，请刷新订单')
        if self._processing_stage(row) == 'NEEDS_REVIEW' and not (allow_review and row.review_authorized_at):
            fail('RECHARGE_REVIEW_REQUIRED', '订单需要人工核对')

    def _require_payment(self, session, row):
        if not row.receipt_id or row.payment_verified_at is None or row.actual_received_usdt is None:
            fail('RECHARGE_PAYMENT_UNVERIFIED', '到账尚未核实，不可结算')
        if not self.wallet_receipts:
            fail('RECHARGE_VERIFIER_UNAVAILABLE', '到账核验服务不可用', 503)
        self.wallet_receipts.require_recharge_reservation(session, request_id=row.id,
            receipt_id=row.receipt_id, user_id=row.user_id, now=self._utcnow())

    def claim_order(self, *, request_id, actor_id, idempotency_key, review=False, reason=None, authorization=None):
        if review and (not reason or len(reason.strip()) < 3):
            fail('RECHARGE_REASON_REQUIRED', '待核对接单需填写原因', 422)
        with self._authorized_transaction(authorization) as session:
            from app.modules.ledger.reserve import lock_budget
            lock_budget(session)
            command = self._claim(session, scope='recharge.owner:'+actor_id, key=idempotency_key,
                payload={'request_id':request_id, 'review':review, 'reason':reason})
            row = self._order(session, request_id)
            if row.status != 'SUBMITTED':
                fail('RECHARGE_ALREADY_DECIDED', '订单已处理')
            if row.expires_at is None:
                fail('RECHARGE_LEGACY_REVIEW_REQUIRED', '历史申请请使用原核对流程')
            if self._processing_stage(row) == 'NEEDS_REVIEW' and not review:
                fail('RECHARGE_REVIEW_REQUIRED', '订单已超时，请进入待核对队列')
            if command.status == 'COMPLETED':
                token = command.response_body.get('claim_token')
                self._require_claim(row, actor_id, token, allow_review=review)
                return dict(self._view(row), claim_token=token)
            now = self._utcnow()
            bound = session.scalar(select(RechargeCreditBinding).where(
                RechargeCreditBinding.request_id==row.id, RechargeCreditBinding.state_active=='1'))
            occupied = row.claim_expires_at and utc(row.claim_expires_at)>now
            if row.claimed_by and row.claimed_by != actor_id:
                if occupied:
                    fail('RECHARGE_CLAIMED_BY_OTHER', '该订单已有客服处理')
                if bound:
                    # A reviewer may recover a stale operator only when the
                    # authoritative financial command proves no execution yet.
                    from app.modules.ledger.adjustment_models import AdjustmentRequest
                    from app.modules.ledger.models import LedgerTransaction
                    adjustment = session.get(AdjustmentRequest,bound.adjustment_id,with_for_update=True)
                    executed = session.scalar(select(LedgerTransaction.id).where(
                        LedgerTransaction.scope=='ledger.adjustment',
                        LedgerTransaction.idempotency_key=='adjustment-execute:'+bound.adjustment_id))
                    if (not review or adjustment is None or adjustment.ledger_transaction_id
                            or adjustment.status not in ('SUBMITTED','FINANCE_APPROVED','ADMIN_APPROVED')
                            or executed):
                        fail('RECHARGE_CLAIMED_BY_OTHER', '该订单需原处理人或资金核对恢复')
            token = secrets.token_urlsafe(32)
            row.claimed_by, row.claim_token_hash = actor_id, hashlib.sha256(token.encode()).hexdigest()
            row.claim_expires_at = now + timedelta(minutes=5)
            if review:
                row.review_authorized_at = now
                row.processing_stage = 'REVIEWING'
                row.payment_verified_at = None
            elif row.processing_stage == 'WAITING_PAYMENT':
                row.processing_stage = 'VERIFYING_PAYMENT'
            self._order_event(session,row,actor_id,'recharge.review_claimed' if review else 'recharge.claimed')
            if review:
                session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='recharge_request',
                    subject_id=row.id, action='recharge.review_authorized', result='SUCCESS',
                    reason_code='RECHARGE_REVIEW_AUTHORIZED', trace_id=row.id[:32],
                    after_data={'reason':reason.strip()[:200]}, created_at=now))
            return self._complete(command, dict(self._view(row), claim_token=token))

    def heartbeat_order(self, *, request_id, actor_id, claim_token, authorization=None):
        with self._authorized_transaction(authorization) as session:
            row = self._order(session, request_id)
            self._require_claim(row, actor_id, claim_token, allow_review=True)
            if row.status != 'SUBMITTED':
                fail('RECHARGE_ALREADY_DECIDED', '订单已处理')
            row.claim_expires_at = self._utcnow()+timedelta(minutes=5)
            return self._view(row)

    def submit_evidence(self, *, request_id, user_id, txid, idempotency_key):
        txid = txid.strip().lower()
        if not re.fullmatch('[a-f0-9]{64}',txid):
            fail('RECHARGE_EVIDENCE_INVALID','请填写完整交易哈希',422)
        with self.factory.begin() as session:
            command = self._claim(session, scope='recharge.evidence:'+user_id, key=idempotency_key,
                payload={'request_id':request_id,'txid':txid})
            row = self._order(session,request_id)
            if row.user_id != user_id: fail('RECHARGE_NOT_FOUND','充值申请不存在',404)
            if command.status == 'COMPLETED': return self._view(row)
            if row.status != 'SUBMITTED' or row.receipt_id:
                fail('RECHARGE_ALREADY_DECIDED','当前状态不可更改付款凭证')
            if row.evidence_txid and row.evidence_txid != txid:
                fail('RECHARGE_EVIDENCE_REVIEW_REQUIRED','已有付款凭证，请由客服核对更正')
            other=session.scalar(select(RechargeRequest.id).where(RechargeRequest.evidence_txid==txid,RechargeRequest.id!=row.id))
            if other: fail('RECHARGE_EVIDENCE_REUSED','该凭证已提交其他订单')
            proof_owner=self._claim(session, scope='recharge.evidence_transaction', key=txid,
                payload={'request_id':request_id}, conflict_code='RECHARGE_EVIDENCE_REUSED')
            self._complete(proof_owner, {'request_id':request_id})
            row.evidence_txid=txid
            row.processing_stage='VERIFYING_PAYMENT'
            self._order_event(session,row,user_id,'recharge.evidence_submitted')
            return self._complete(command,self._view(row))

    def verify_order_payment(self, *, request_id, actor_id, claim_token, txid, log_index,
                             idempotency_key, authorization=None):
        if self.wallet_receipts is None:
            fail('RECHARGE_VERIFIER_UNAVAILABLE','到账核验服务不可用',503)
        txid=txid.strip().lower()
        if not re.fullmatch('[a-f0-9]{64}',txid) or type(log_index) is not int or log_index<0:
            fail('RECHARGE_EVIDENCE_INVALID','交易凭证格式无效',422)
        with self._authorized_transaction(authorization) as session:
            row=session.get(RechargeRequest,request_id)
            if row is None: fail('RECHARGE_NOT_FOUND','充值申请不存在',404)
            self._require_claim(row,actor_id,claim_token,allow_review=True)
            from app.core.idempotency import IdempotencyRecord
            previous=session.scalar(select(IdempotencyRecord).where(
                IdempotencyRecord.scope=='recharge.verify:'+actor_id,
                IdempotencyRecord.idempotency_key==idempotency_key))
            if previous is not None:
                command=self._claim(session,scope='recharge.verify:'+actor_id,key=idempotency_key,
                    payload={'request_id':request_id,'txid':txid,'log_index':log_index})
                if command.status=='COMPLETED':
                    return self._view(row)
        # Network calls occur outside the final short transaction. Fresh proof is
        # rechecked against locked ownership and immutable receipt in reservation.
        proof=self.wallet_receipts.recharge_evidence(txid)
        with self._authorized_transaction(authorization) as session:
            command=self._claim(session,scope='recharge.verify:'+actor_id,key=idempotency_key,
                payload={'request_id':request_id,'txid':txid,'log_index':log_index})
            from app.modules.ledger.reserve import lock_budget
            lock_budget(session)
            row=self._order(session,request_id)
            self._require_claim(row,actor_id,claim_token,allow_review=True)
            if command.status=='COMPLETED':
                return self._view(row)
            if row.status!='SUBMITTED': fail('RECHARGE_ALREADY_DECIDED','订单已处理')
            if row.evidence_txid and row.evidence_txid!=txid:
                fail('RECHARGE_EVIDENCE_CONFLICT','凭证与用户提交不一致')
            proof_owner=self._claim(session, scope='recharge.evidence_transaction', key=txid,
                payload={'request_id':request_id}, conflict_code='RECHARGE_EVIDENCE_REUSED')
            self._complete(proof_owner, {'request_id':request_id})
            view=self.wallet_receipts.reserve_recharge_payment(session,request_id=row.id,
                user_id=row.user_id,official_payment=row.official_payment,created_at=row.created_at,
                proof=proof,log_index=log_index,actor_id=actor_id,now=self._utcnow())
            row.receipt_id=view['receipt_id']
            row.actual_received_usdt=Decimal(view['amount_usdt'])
            row.payment_verified_at=self._utcnow()
            row.evidence_txid=txid
            row.processing_stage='PAYMENT_VERIFIED'
            self._order_event(session,row,actor_id,'recharge.payment_verified')
            return self._complete(command,self._view(row))

    def order_events(self, *, actor_id, cursor=None, limit=50):
        from app.modules.recharge.notifications import SupportOrderNotifications
        return SupportOrderNotifications(self.factory).poll(actor_id=actor_id, cursor=cursor, limit=limit)

    def prepare_settlement(self, *, request_id, actor_id, claim_token, final_rate,
                           idempotency_key, authorization=None):
        self._require_settlement_enabled()
        from app.modules.ledger.adjustments import AdjustmentWorkflow
        from app.modules.ledger.reserve import lock_budget
        workflow = AdjustmentWorkflow(self.factory, self.ledger,
            admin_threshold=getattr(self, 'adjustment_admin_threshold', Decimal('10000')))
        with self._authorized_transaction(authorization) as session:
            lock_budget(session)
            rate = self._amount(final_rate, '0.000001')
            command = self._claim(session, scope='recharge.settlement.prepare:'+actor_id,
                key=idempotency_key, payload={'request_id':request_id, 'final_rate':str(rate)})
            row = self._order(session, request_id)
            self._require_claim(row, actor_id, claim_token, allow_review=True)
            if command.status == 'COMPLETED':
                return command.response_body
            if row.status != 'SUBMITTED' or row.expires_at is None:
                fail('RECHARGE_SETTLEMENT_NOT_ALLOWED', '当前订单不可提交结算')
            self._require_payment(session, row)
            self._require_unbound(session, row.id)
            adjustment = workflow.submit_support_recharge(session=session, request_id=row.id,
                actor_id=actor_id, claim_token=claim_token, final_rate=rate,
                idempotency_key=idempotency_key)
            bound = self.bind_finance_adjustment(request_id=row.id, actor_id=actor_id,
                adjustment_id=adjustment.id, claim_token=claim_token, final_rate=rate,
                idempotency_key='prepare:'+adjustment.id, session=session)
            self._order_event(session, row, actor_id, 'recharge.settlement_submitted')
            return self._complete(command, {**self._view(row), 'adjustment_id':adjustment.id,
                'binding_state':bound['state'], 'settlement_status':adjustment.status})

    def execute_settlement(self, *, request_id, actor_id, claim_token, idempotency_key,
                           authorization=None):
        self._require_settlement_enabled()
        from app.modules.ledger.adjustments import AdjustmentWorkflow
        from app.modules.ledger.adjustment_models import AdjustmentRequest
        from app.modules.ledger.reserve import lock_budget
        workflow = AdjustmentWorkflow(self.factory, self.ledger,
            admin_threshold=getattr(self, 'adjustment_admin_threshold', Decimal('10000')))
        with self._authorized_transaction(authorization) as session:
            lock_budget(session)
            command = self._claim(session, scope='recharge.settlement.execute:'+actor_id,
                key=idempotency_key, payload={'request_id':request_id})
            row = self._order(session, request_id)
            if row.status == 'CREDITED':
                return self._complete(command, self._view(row))
            self._require_claim(row, actor_id, claim_token, allow_review=True)
            binding = session.scalar(select(RechargeCreditBinding).where(
                RechargeCreditBinding.request_id==row.id, RechargeCreditBinding.state_active=='1'))
            if binding is None:
                fail('RECHARGE_BINDING_NOT_FOUND', '请先提交结算审批')
            adjustment = session.get(AdjustmentRequest, binding.adjustment_id, with_for_update=True)
            if adjustment is None or adjustment.status not in ('FINANCE_APPROVED','ADMIN_APPROVED','EXECUTED'):
                fail('PENDING_APPROVAL', '等待独立财务审批后执行')
            if adjustment.status != 'EXECUTED':
                self._require_payment(session, row)
                workflow.execute(adjustment.id, actor_id=actor_id,
                    idempotency_key=idempotency_key, session=session,
                    support_claim_token=claim_token, support_authorization=authorization)
            self._order_event(session, row, actor_id, 'recharge.settlement_executed')
            self._complete(command, {'request_id':row.id, 'ledger_transaction_id':adjustment.ledger_transaction_id})
        # Execution is already committed. A lost response is recovered by the
        # existing registration worker; registration can never credit again.
        return self.complete_bound(request_id=request_id, actor_id=actor_id,
            claim_token=claim_token, authorization=authorization)

    def expire_orders(self, *, limit=100):
        with self.factory.begin() as session:
            rows = list(session.scalars(select(RechargeRequest).where(
                RechargeRequest.status == 'SUBMITTED', RechargeRequest.expires_at <= self._utcnow(),
                RechargeRequest.review_authorized_at.is_(None),
                RechargeRequest.processing_stage != 'NEEDS_REVIEW').order_by(
                    RechargeRequest.expires_at, RechargeRequest.id).limit(limit).with_for_update(skip_locked=True)))
            for row in rows:
                row.processing_stage = 'NEEDS_REVIEW'
                self._order_event(session, row, 'support-order-expiry-worker', 'recharge.expired')
            return len(rows)
