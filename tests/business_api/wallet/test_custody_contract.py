from decimal import Decimal
from app.integrations.custody.sandbox import SandboxCustodyProvider

def test_sandbox_provider_contract_is_deterministic_and_signed():
    provider = SandboxCustodyProvider(secret="contract-secret")
    assert provider.create_deposit_address("user-1").startswith("T_SANDBOX_")
    txid = provider.submit_withdrawal(client_order_id="order-1", address="TTEST", amount=Decimal("1.000000"))
    assert provider.get_withdrawal("order-1")["txid"] == txid
    event = provider.withdrawal_event(client_order_id="order-1", status="CHAIN_CONFIRMED", confirmations=20, event_id="event-1")
    assert provider.sign(event.payload) == event.signature
    assert provider.deposit_event(user_id="user-1", amount=Decimal("2.123456"), confirmations=12, event_id="deposit-1").payload["asset"] == "USDT-TRC20"
