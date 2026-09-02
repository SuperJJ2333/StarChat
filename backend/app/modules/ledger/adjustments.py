from datetime import datetime, timezone
from decimal import Decimal
from uuid import uuid4

from sqlalchemy import func, select

from app.modules.ledger.adjustment_models import AdjustmentPolicy, AdjustmentRequest
from app.modules.ledger.service import LedgerService, money

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

    def submit(self, *, actor_id: str, user_id: str, amount: Decimal, reason_code: str, idempotency_key: str) -> AdjustmentRequest:
        amount = money(amount)
        if amount == 0 or not reason_code or not idempotency_key:
            raise ValueError("amount, reason and idempotency are required")
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
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

    def admin_review(self, request_id: str, *, reviewer_id: str, approve: bool) -> AdjustmentRequest:
        # A system administrator may execute the modification directly.  The
        # command still records the actor and follows the state machine, but it
        # does not require a preceding finance approval or amount threshold.
        with self.session_factory.begin() as session:
            request = session.get(AdjustmentRequest, request_id)
            if not request or request.status not in {"SUBMITTED", "FINANCE_APPROVED"}:
                raise ValueError("illegal approval transition")
            request.admin_reviewer_id = reviewer_id
            request.status = "ADMIN_APPROVED" if approve else "REJECTED"
            request.updated_at = datetime.now(timezone.utc)
            session.flush()
            return request

    def _review(self, request_id, reviewer_id, approve, expected, approved_status, reviewer_field):
        with self.session_factory.begin() as session:
            request = session.get(AdjustmentRequest, request_id)
            if not request or request.status != expected:
                raise ValueError("illegal approval transition")
            setattr(request, reviewer_field, reviewer_id)
            request.status = approved_status if approve else "REJECTED"
            request.updated_at = datetime.now(timezone.utc)
            session.flush()
            return request

    def execute(self, request_id: str, *, actor_id: str, idempotency_key: str) -> AdjustmentRequest:
        with self.session_factory() as session:
            request = session.get(AdjustmentRequest, request_id)
            if not request:
                raise ValueError("request not found")
            if request.status == "EXECUTED":
                return request
            if request.status != "FINANCE_APPROVED":
                if request.status != "ADMIN_APPROVED":
                    raise ValueError("request is not approved")
            user_id, amount, reason = request.user_id, request.amount, request.reason_code
        tx = self.ledger.adjust(user_id=user_id, amount=amount, actor_id=actor_id, reason_code=reason, idempotency_key=idempotency_key)
        with self.session_factory.begin() as session:
            request = session.get(AdjustmentRequest, request_id)
            request.status, request.ledger_transaction_id, request.updated_at = "EXECUTED", tx.id, datetime.now(timezone.utc)
            session.flush()
            return request
