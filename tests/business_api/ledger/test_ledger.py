from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService, PointTransferService

@pytest.fixture()
def factory():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    result = create_session_factory(engine)
    yield result
    engine.dispose()

def test_transfer_debits_sender_extra_half_percent_fee(factory):
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("100.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-1")
    result = PointTransferService(ledger).transfer(sender_id="alice", receiver_id="bob", amount=Decimal("10.00"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="transfer-1")
    assert result.fee == Decimal("0.05")
    assert ledger.balance("alice") == Decimal("89.95")
    assert ledger.balance("bob") == Decimal("10.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.05")
    assert sum(entry.amount for entry in result.transaction.entries) == Decimal("0.00")

def test_minimum_fee_rounding_and_idempotent_replay(factory):
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("1.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed")
    transfers = PointTransferService(ledger)
    first = transfers.transfer(sender_id="alice", receiver_id="bob", amount=Decimal("0.01"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="same")
    replay = transfers.transfer(sender_id="alice", receiver_id="bob", amount=Decimal("0.01"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="same")
    assert first.fee == Decimal("0.01")
    assert replay.transaction.id == first.transaction.id
    assert ledger.balance("bob") == Decimal("0.01")

def test_rejects_unbalanced_or_overdraft(factory):
    ledger = LedgerService(factory)
    with pytest.raises(ValueError, match="balanced"):
        ledger.post(entries={"alice": Decimal("1.00")}, actor_id="admin", reason_code="BAD", idempotency_key="bad")
    with pytest.raises(ValueError, match="insufficient"):
        PointTransferService(ledger).transfer(sender_id="alice", receiver_id="bob", amount=Decimal("1.00"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="overdraft")

def test_idempotency_key_rejects_different_transfer_payload(factory):
    ledger = LedgerService(factory)
    ledger.adjust(user_id="alice", amount=Decimal("10.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-idem")
    transfers = PointTransferService(ledger)
    transfers.transfer(sender_id="alice", receiver_id="bob", amount=Decimal("1.00"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="transfer-idem")
    with pytest.raises(ValueError, match="different payload"):
        transfers.transfer(sender_id="alice", receiver_id="bob", amount=Decimal("2.00"), actor_id="alice", reason_code="USER_TRANSFER", idempotency_key="transfer-idem")
