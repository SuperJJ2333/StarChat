from dataclasses import dataclass
from decimal import Decimal
from typing import Protocol

class CustodyProvider(Protocol):
    def create_deposit_address(self, user_id: str) -> str: ...
    def submit_withdrawal(self, *, client_order_id: str, address: str, amount: Decimal) -> str: ...
    def get_withdrawal(self, client_order_id: str) -> dict: ...

@dataclass(frozen=True)
class CustodyWebhook:
    payload: dict
    signature: str
