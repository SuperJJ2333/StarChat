from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider
from app.modules.wallet.service import WalletService


@pytest.mark.parametrize("amount, status", [
    ("9.999999", "MANUAL_REVIEW"),
    ("10.000000", "CREDITED"),
    ("10.000001", "CREDITED"),
])
def test_each_deposit_obeys_ten_usdt_minimum(amount, status):
    engine = create_engine("sqlite://", poolclass=StaticPool)
    Base.metadata.create_all(engine)
    provider = SandboxCustodyProvider(secret="isolated-minimum-policy-test")
    service = WalletService(create_session_factory(engine), provider)
    event = provider.deposit_event(user_id="minimum-user", amount=Decimal(amount),
                                   confirmations=20, event_id="minimum-event")
    assert service.handle_deposit_webhook(event.payload, event.signature) == status
    assert service.handle_deposit_webhook(event.payload, event.signature) == status
    expected = Decimal(amount) if status == "CREDITED" else Decimal("0")
    assert service.usdt_balance("minimum-user") == expected
    engine.dispose()


def test_public_minimums_match_processing_policy():
    config = WalletService(None, None).config()
    assert config["min_deposit"] == "10.000000"
    assert config["min_withdrawal"] == "10.000000"
