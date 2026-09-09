from decimal import Decimal
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.service import WalletService
from tasks.wallet import WalletMaintenanceTask

def test_wallet_maintenance_reconciles_and_resolves_unknown():
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    provider = SandboxCustodyProvider(secret="offline-worker-test")
    provider.custody_balance = Decimal("20.000000")
    service = WalletService(factory, provider, confirmation_threshold=20)
    service.credit_for_test("u", Decimal("20.000000"))
    row = service.request_withdrawal(
        user_id="u", amount=Decimal("10.000000"), address="T_OFFLINE",
        client_order_id="o", reason_code="USER_WITHDRAWAL",
    )
    service.finance_approve(row.id, "finance")
    service.admin_approve(row.id, "admin")
    service.submit_to_custody(row.id, "worker")
    assert service.balances("u")["usdt_held"] == "10.000000"

    # Queryable external evidence arrives without delivering its callback.
    # The worker must query that evidence and settle the original hold.
    provider.withdrawal_event(
        client_order_id=row.id, status="CHAIN_CONFIRMED",
        confirmations=20, event_id="worker-finality",
    )
    result = WalletMaintenanceTask(factory, service).run_once()
    assert result["resolved"] == 1
    assert result["reconciliation"].matched is True
    assert service.withdrawal_status(row.id, "u")["status"] == "CHAIN_CONFIRMED"
    assert service.balances("u")["usdt_held"] == "0.000000"
    assert service.usdt_balance("u") == Decimal("10.000000")
    assert provider.custody_balance == Decimal("10.000000")
    assert WalletMaintenanceTask(factory, service).run_once()["resolved"] == 0
    engine.dispose()
