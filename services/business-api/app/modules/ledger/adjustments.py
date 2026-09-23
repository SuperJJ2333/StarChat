from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4
from contextlib import nullcontext
import hashlib

from sqlalchemy import func, select

from app.modules.ledger.adjustment_models import AdjustmentPolicy, AdjustmentRequest
from app.modules.ledger.service import LedgerService, money
from app.modules.recharge.execution import prepare_adjustment_execution, finish_adjustment_execution, lock_execution_scope
from app.modules.recharge.execution import support_adjustment_terms, require_execution_authorization
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent

class AdjustmentWorkflow:
    def __init__(self, session_factory, ledger: LedgerService, *, admin_threshold: Decimal):
        self.session_factory = session_factory
        self.ledger = ledger
        self.admin_threshold = money(admin_threshold)

    def set_policy(self, actor_id: str, *, per_transaction: Decimal, per_day: Decimal, allowed_users: set[str]):
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
            row = session.get(AdjustmentPolicy, actor_id)
            if row is None:
                session.add(AdjustmentPolicy(actor_id=actor_id, per_transaction=money(per_transaction), per_day=money(per_day), allowed_users=sorted(allowed_users), updated_at=now))
            else:
                row.per_transaction, row.per_day, row.allowed_users, row.updated_at = money(per_transaction), money(per_day), sorted(allowed_users), now

    def submit(self, *, actor_id: str, user_id: str, amount: Decimal, reason_code: str, idempotency_key: str, session=None) -> AdjustmentRequest:
        """Public submission boundary; an optional caller transaction binds the order atomically."""
        if idempotency_key and idempotency_key.startswith('support-recharge:'):
            raise ValueError('support recharge idempotency namespace is reserved')
        amount = money(amount)
        if amount == 0 or not reason_code or not idempotency_key:
            raise ValueError("amount, reason and idempotency are required")
        now = datetime.now(timezone.utc)
        with (self.session_factory.begin() if session is None else nullcontext(session)) as session:
            existing = session.scalar(select(AdjustmentRequest).where(AdjustmentRequest.submitted_by == actor_id, AdjustmentRequest.idempotency_key == idempotency_key))
            if existing:
                return existing
            policy = session.get(AdjustmentPolicy, actor_id)
            if policy is None:
                raise ValueError("adjustment policy missing")
            if user_id not in policy.allowed_users:
                raise ValueError("user is outside allowed scope")
            if abs(amount) > policy.per_transaction:
                raise ValueError("single transaction limit exceeded")
            used = session.scalar(select(func.coalesce(func.sum(func.abs(AdjustmentRequest.amount)), 0)).where(AdjustmentRequest.submitted_by == actor_id, AdjustmentRequest.business_date == now.date(), AdjustmentRequest.status != "REJECTED"))
            if money(Decimal(used)) + abs(amount) > policy.per_day:
                raise ValueError("daily limit exceeded")
            request = AdjustmentRequest(id=str(uuid4()), user_id=user_id, amount=amount, reason_code=reason_code, status="SUBMITTED", submitted_by=actor_id, idempotency_key=idempotency_key, business_date=now.date(), created_at=now, updated_at=now)
            session.add(request)
            session.flush()
            return request

    def finance_review(self, request_id: str, *, reviewer_id: str, approve: bool) -> AdjustmentRequest:
        return self._review(request_id, reviewer_id, approve, "SUBMITTED", "FINANCE_APPROVED", "finance_reviewer_id")

    def submit_support_recharge(self, *, session, request_id, actor_id, claim_token,
                                final_rate, idempotency_key):
        """Narrow verified-order submission; execution uses the scoped recharge boundary.

        The caller supplies its transaction and must bind this returned request
        before committing; execution fails closed for an unbound support request.
        Ordinary adjustment policy permissions remain unchanged.
        """
        if not actor_id or not idempotency_key:
            raise ValueError('actor and idempotency key are required')
        now = datetime.now(timezone.utc)
        user_id, amount = support_adjustment_terms(session, request_id=request_id,
            actor_id=actor_id, claim_token=claim_token, final_rate=final_rate, now=now)
        key = 'support-recharge:' + hashlib.sha256((request_id + ':' + idempotency_key).encode()).hexdigest()
        existing = session.scalar(select(AdjustmentRequest).where(
            AdjustmentRequest.submitted_by == actor_id, AdjustmentRequest.idempotency_key == key))
        if existing is not None:
            if existing.user_id != user_id or existing.amount != amount or existing.reason_code != 'RECHARGE_CREDIT':
                raise AppError(code='IDEMPOTENCY_CONFLICT', message='同一申请的结算参数不能变更', status_code=409)
            return existing
        request = AdjustmentRequest(id=str(uuid4()), user_id=user_id, amount=amount,
            reason_code='RECHARGE_CREDIT', status='SUBMITTED', submitted_by=actor_id,
            idempotency_key=key, business_date=now.date(), created_at=now, updated_at=now)
        session.add(request)
        session.flush()
        session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='adjustment_request',
            subject_id=request.id, action='recharge.adjustment_submitted', result='SUCCESS',
            reason_code='RECHARGE_CREDIT', trace_id=request.id[:32],
            after_data={'request_id': request_id, 'amount': str(amount)}, created_at=now))
        OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.adjustment_submitted',
            aggregate_type='recharge_request', aggregate_id=request_id,
            payload={'request_id': request_id, 'adjustment_id': request.id}, now=now)
        return request

    def admin_review(self, request_id: str, *, reviewer_id: str, approve: bool) -> AdjustmentRequest:
        # A system administrator may execute the modification directly.  The
        # command still records the actor and follows the state machine, but it
        # does not require a preceding finance approval or amount threshold.
        with self.session_factory.begin() as session:
            request = session.get(AdjustmentRequest, request_id, with_for_update=True)
            if not request or request.status not in {"SUBMITTED", "FINANCE_APPROVED"}:
                raise ValueError("illegal approval transition")
            self._support_review_audit(session, request, reviewer_id, approve)
            request.admin_reviewer_id = reviewer_id
            request.status = "ADMIN_APPROVED" if approve else "REJECTED"
            request.updated_at = datetime.now(timezone.utc)
            session.flush()
            return request

    def _review(self, request_id, reviewer_id, approve, expected, approved_status, reviewer_field):
        with self.session_factory.begin() as session:
            request = session.get(AdjustmentRequest, request_id, with_for_update=True)
            if not request or request.status != expected:
                raise ValueError("illegal approval transition")
            self._support_review_audit(session, request, reviewer_id, approve)
            setattr(request, reviewer_field, reviewer_id)
            request.status = approved_status if approve else "REJECTED"
            request.updated_at = datetime.now(timezone.utc)
            session.flush()
            return request

    def _support_review_audit(self, session, request, reviewer_id, approve):
        if not request.idempotency_key.startswith('support-recharge:'):
            return
        if approve and reviewer_id == request.submitted_by:
            raise AppError(code='RECHARGE_INDEPENDENT_APPROVAL_REQUIRED', message='充值结算需要独立财务审批', status_code=409)
        now = datetime.now(timezone.utc)
        outcome = 'APPROVED' if approve else 'REJECTED'
        session.add(AuditEvent(id=str(uuid4()), actor_id=reviewer_id, subject_type='adjustment_request',
            subject_id=request.id, action='recharge.adjustment_reviewed', result='SUCCESS',
            reason_code='RECHARGE_CREDIT', trace_id=request.id[:32],
            before_data={'status': request.status}, after_data={'decision': outcome}, created_at=now))
        OutboxPublisher.enqueue(session, topic='recharge', event_type='recharge.adjustment_reviewed',
            aggregate_type='adjustment_request', aggregate_id=request.id,
            payload={'adjustment_id': request.id, 'decision': outcome, 'reviewer_id': reviewer_id}, now=now)

    def execute(self, request_id: str, *, actor_id: str, idempotency_key: str, session=None,
                support_claim_token=None, support_authorization=None) -> AdjustmentRequest:
        """F02：同一审批单只执行一次。

        - 执行幂等键由服务端从 adjustment_request_id 派生（与 HTTP 请求
          幂等键无关——不同请求键重放同一审批单不得产生第二笔记账）；
        - 审批单行 FOR UPDATE 锁定串行化并发执行；
        - 账本记账与 EXECUTED 终态在**同一事务**提交：记账后崩溃整体
          回滚；崩溃后重试经账本幂等键返回同一交易并补齐终态。
        """
        return self._execute(request_id, actor_id=actor_id, idempotency_key=idempotency_key,
            session=session, support_claim_token=support_claim_token,
            support_authorization=support_authorization, direct_recharge=False)

    def execute_support_recharge(self, request_id: str, *, actor_id: str, idempotency_key: str,
                                 support_claim_token, support_authorization, session=None):
        """ADR-0084: execute only a verified order-derived recharge, without a reviewer.

        No recipient/amount is accepted here. Existing approval records stay intact;
        ordinary adjustments retain their approval gate and cannot enter this path.
        """
        return self._execute(request_id, actor_id=actor_id, idempotency_key=idempotency_key,
            session=session, support_claim_token=support_claim_token,
            support_authorization=support_authorization, direct_recharge=True)

    def _execute(self, request_id, *, actor_id, idempotency_key, session,
                 support_claim_token, support_authorization, direct_recharge):
        execution_key = f"adjustment-execute:{request_id}"
        with (self.session_factory.begin() if session is None else nullcontext(session)) as session:
            fresh = support_authorization(session) if support_authorization is not None else None
            order = lock_execution_scope(session, adjustment_id=request_id)
            require_execution_authorization(order, actor_id=actor_id, claim_token=support_claim_token,
                fresh=fresh, now=datetime.now(timezone.utc))
            request = session.get(AdjustmentRequest, request_id, with_for_update=True)
            if not request:
                raise ValueError("request not found")
            if direct_recharge and (order is None or order.expires_at is None
                    or not request.idempotency_key.startswith('support-recharge:')
                    or request.reason_code != 'RECHARGE_CREDIT'):
                raise AppError(code='RECHARGE_DIRECT_SCOPE_REQUIRED',
                    message='只有订单专用的已核验充值可直接下发', status_code=409)
            if request.status == "EXECUTED":
                if callable(fresh): fresh()
                return request
            allowed = ('SUBMITTED', 'FINANCE_APPROVED', 'ADMIN_APPROVED') if direct_recharge else ('FINANCE_APPROVED', 'ADMIN_APPROVED')
            if request.status not in allowed:
                raise ValueError("request is not approved")
            prepared = prepare_adjustment_execution(session, adjustment=request, actor_id=actor_id,
                now=datetime.now(timezone.utc), reserve_policy=self.ledger.reserve_policy,
                direct_recharge=direct_recharge)
            tx = self.ledger.adjust(
                user_id=request.user_id,
                amount=request.amount,
                actor_id=actor_id,
                reason_code=request.reason_code,
                idempotency_key=execution_key,
                session=session,
            )
            request.status, request.ledger_transaction_id, request.updated_at = "EXECUTED", tx.id, datetime.now(timezone.utc)
            session.flush()
            finish_adjustment_execution(session, prepared=prepared, ledger_transaction_id=tx.id)
            if direct_recharge:
                now = datetime.now(timezone.utc)
                session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id,
                    subject_type='recharge_request', subject_id=order.id,
                    action='recharge.direct_settlement_executed', result='SUCCESS',
                    reason_code='RECHARGE_CREDIT', trace_id=request.id[:32],
                    after_data={'adjustment_id': request.id, 'ledger_transaction_id': tx.id,
                                'amount': str(request.amount), 'approval_required': False}, created_at=now))
                OutboxPublisher.enqueue(session, topic='recharge',
                    event_type='recharge.direct_settlement_executed',
                    aggregate_type='recharge_request', aggregate_id=order.id,
                    payload={'request_id': order.id, 'adjustment_id': request.id,
                             'ledger_transaction_id': tx.id}, now=now)
            if callable(fresh): fresh()
            return request
