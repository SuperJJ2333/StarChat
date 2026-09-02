from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.wallet.service import WalletService
from app.integrations.custody.sandbox import SandboxCustodyProvider

@pytest.fixture()
def wallet():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    provider = SandboxCustodyProvider(secret="sandbox-webhook-secret")
    service = WalletService(factory, provider, withdrawal_admin_threshold=Decimal("1000.000000"))
    yield service, provider
    engine.dispose()

def test_duplicate_signed_deposit_webhook_credits_once(wallet):
    service, provider = wallet
    event = provider.deposit_event(user_id="user-1", amount=Decimal("12.345678"), confirmations=20, event_id="deposit-1")
    assert service.handle_deposit_webhook(event.payload, event.signature) == "CREDITED"
    assert service.handle_deposit_webhook(event.payload, event.signature) == "CREDITED"
    assert service.usdt_balance("user-1") == Decimal("12.345678")

def test_withdrawal_submits_after_the_admin_direct_review(wallet):
    service, provider = wallet
    service.credit_for_test("user-1", Decimal("2000.000000"))
    request = service.request_withdrawal(user_id="user-1", amount=Decimal("1500.000000"), address="TTEST", client_order_id="wd-1", reason_code="USER_WITHDRAWAL")
    service.finance_approve(request.id, approver_id="admin-1")
    submitted = service.submit_to_custody(request.id, actor_id="admin-1")
    assert submitted.status == "PROVIDER_SUBMITTED"

def test_admin_can_approve_requested_withdrawal_without_finance_step(wallet):
    service, provider = wallet
    service.credit_for_test("user-direct", Decimal("20.000000"))
    request = service.request_withdrawal(user_id="user-direct", amount=Decimal("2.000000"), address="TDIRECT", client_order_id="wd-direct", reason_code="ADMIN_DIRECT")
    approved = service.admin_approve(request.id, approver_id="admin-1")
    assert approved.status == "ADMIN_APPROVED"
    submitted = service.submit_to_custody(request.id, actor_id="admin-1")
    assert submitted.status == "PROVIDER_SUBMITTED"

def test_reconciliation_mismatch_pauses_withdrawals(wallet):
    service, provider = wallet
    service.pause_on_reconciliation_mismatch("balance mismatch")
    assert service.withdrawals_paused() is True
