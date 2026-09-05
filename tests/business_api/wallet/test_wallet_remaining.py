from decimal import Decimal
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.service import WalletService

@pytest.fixture()
def wallet():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    provider = SandboxCustodyProvider(secret="contract-secret")
    service = WalletService(factory, provider, withdrawal_admin_threshold=Decimal("1000.000000"))
    yield service, provider, factory
    engine.dispose()

def test_withdrawal_confirmation_webhook_is_idempotent(wallet):
    service, provider, _ = wallet
    service.credit_for_test("u1", Decimal("20.000000"))
    row = service.request_withdrawal(user_id="u1", amount=Decimal("2.000000"), address="T1", client_order_id="order-1", reason_code="USER_WITHDRAWAL")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")
    event = provider.withdrawal_event(client_order_id="order-1", status="CHAIN_CONFIRMED", confirmations=20, event_id="wd-event-1")
    assert service.handle_withdrawal_webhook(event.payload, event.signature) == "CHAIN_CONFIRMED"
    assert service.handle_withdrawal_webhook(event.payload, event.signature) == "CHAIN_CONFIRMED"

def test_unknown_withdrawal_result_is_queried_by_original_order(wallet):
    service, provider, _ = wallet
    service.credit_for_test("u2", Decimal("20.000000"))
    row = service.request_withdrawal(user_id="u2", amount=Decimal("2.000000"), address="T2", client_order_id="order-2", reason_code="USER_WITHDRAWAL")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")
    provider.withdrawals[row.id]["status"] = "CHAIN_CONFIRMED"
    assert service.resolve_unknown_withdrawal(row.id, actor_id="worker").status == "CHAIN_CONFIRMED"

def test_incremental_reconciliation_pauses_on_mismatch(wallet):
    service, provider, _ = wallet
    service.credit_for_test("u3", Decimal("5.000000"))
    provider.custody_balance = Decimal("99.000000")
    result = service.reconcile_incremental(actor_id="worker")
    assert result.matched is False
    assert service.withdrawals_paused() is True
