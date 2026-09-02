from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.adjustments import AdjustmentWorkflow
from app.modules.ledger.service import LedgerService

@pytest.fixture()
def workflow():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    flow = AdjustmentWorkflow(factory, LedgerService(factory), admin_threshold=Decimal("1000.00"))
    flow.set_policy("support-1", per_transaction=Decimal("2000.00"), per_day=Decimal("3000.00"), allowed_users={"user-1"})
    yield flow
    engine.dispose()

def test_small_adjustment_requires_finance_review_then_executes(workflow):
    request = workflow.submit(actor_id="support-1", user_id="user-1", amount=Decimal("100.00"), reason_code="SUPPORT_CREDIT", idempotency_key="adj-1")
    assert request.status == "SUBMITTED"
    reviewed = workflow.finance_review(request.id, reviewer_id="finance-1", approve=True)
    assert reviewed.status == "FINANCE_APPROVED"
    executed = workflow.execute(request.id, actor_id="finance-1", idempotency_key="execute-1")
    assert executed.status == "EXECUTED"

def test_large_adjustment_executes_after_the_admin_direct_review(workflow):
    request = workflow.submit(actor_id="support-1", user_id="user-1", amount=Decimal("1500.00"), reason_code="SUPPORT_CREDIT", idempotency_key="adj-2")
    reviewed = workflow.finance_review(request.id, reviewer_id="admin-1", approve=True)
    assert reviewed.status == "FINANCE_APPROVED"
    assert workflow.execute(request.id, actor_id="admin-1", idempotency_key="execute-2").status == "EXECUTED"

def test_admin_can_review_submitted_adjustment_without_finance_approval(workflow):
    request = workflow.submit(actor_id="support-1", user_id="user-1", amount=Decimal("10.00"), reason_code="ADMIN_DIRECT", idempotency_key="adj-direct")
    reviewed = workflow.admin_review(request.id, reviewer_id="admin-1", approve=True)
    assert reviewed.status == "ADMIN_APPROVED"
    assert workflow.execute(request.id, actor_id="admin-1", idempotency_key="execute-direct").status == "EXECUTED"

def test_policy_limits_and_user_scope_are_enforced(workflow):
    with pytest.raises(ValueError, match="scope"):
        workflow.submit(actor_id="support-1", user_id="other", amount=Decimal("1.00"), reason_code="SUPPORT_CREDIT", idempotency_key="bad-scope")
    with pytest.raises(ValueError, match="single"):
        workflow.submit(actor_id="support-1", user_id="user-1", amount=Decimal("2000.01"), reason_code="SUPPORT_CREDIT", idempotency_key="bad-limit")
