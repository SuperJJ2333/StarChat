from decimal import Decimal
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.service import WalletService
from tasks.wallet import WalletMaintenanceTask

def test_wallet_maintenance_reconciles_and_resolves_unknown():
    engine=create_engine("sqlite+pysqlite:///:memory:",connect_args={"check_same_thread":False},poolclass=StaticPool); Base.metadata.create_all(engine); factory=create_session_factory(engine); provider=SandboxCustodyProvider(secret="x"); service=WalletService(factory,provider); service.credit_for_test("u",Decimal("5.000000")); row=service.request_withdrawal(user_id="u",amount=Decimal("1.000000"),address="T",client_order_id="o",reason_code="USER_WITHDRAWAL"); service.finance_approve(row.id,"finance"); service.submit_to_custody(row.id,"finance"); provider.withdrawals[row.id]["status"]="CHAIN_CONFIRMED"; provider.custody_balance=Decimal("4.000000"); result=WalletMaintenanceTask(factory,service).run_once(); assert result["resolved"]==1; assert result["reconciliation"].matched is True; engine.dispose()
