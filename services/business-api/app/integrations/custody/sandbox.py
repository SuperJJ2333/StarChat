import hashlib
import hmac
import json
from dataclasses import dataclass
from decimal import Decimal

@dataclass(frozen=True)
class SandboxWebhook:
    payload: dict
    signature: str

class SandboxCustodyProvider:
    def __init__(self, *, secret: str):
        self.secret = secret.encode()
        self.withdrawals = {}

    def create_deposit_address(self, user_id: str) -> str:
        return f"T_SANDBOX_{user_id[:16]}"

    def submit_withdrawal(self, *, client_order_id: str, address: str, amount: Decimal) -> str:
        txid = f"sandbox-tx-{client_order_id}"
        self.withdrawals[client_order_id] = {"client_order_id": client_order_id, "txid": txid, "status": "SUBMITTED", "address": address, "amount": str(amount)}
        return txid

    def get_withdrawal(self, client_order_id: str) -> dict:
        return self.withdrawals.get(client_order_id, {"client_order_id": client_order_id, "status": "UNKNOWN"})

    def deposit_event(self, *, user_id: str, amount: Decimal, confirmations: int, event_id: str) -> SandboxWebhook:
        payload = {"event_id": event_id, "type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20", "user_id": user_id, "amount": str(Decimal(amount).quantize(Decimal("0.000001"))), "confirmations": confirmations, "txid": f"sandbox-deposit-{event_id}"}
        return SandboxWebhook(payload, self.sign(payload))

    def sign(self, payload: dict) -> str:
        raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return hmac.new(self.secret, raw, hashlib.sha256).hexdigest()
