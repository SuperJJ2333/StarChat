from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.transfer.service import ChatTransferService


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("300.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-sender")
    ledger.adjust(user_id="receiver", amount=Decimal("1.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-receiver")
    service = ChatTransferService(factory, ledger)
    yield factory, ledger, service
    engine.dispose()


def test_transfer_create_escrows_amount_and_charges_sender_fee(context):
    factory, ledger, service = context
    transfer = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("100.00"), note="晚饭钱", room_id=None, idempotency_key="t1", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert transfer.status == "PENDING"
    assert transfer.amount == Decimal("100.00")
    assert transfer.fee == Decimal("0.50")
    assert ledger.balance("sender") == Decimal("300.00") - Decimal("100.50")
    assert ledger.balance(f"PLATFORM_TRANSFER_ESCROW:{transfer.id}") == Decimal("100.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.50")
    assert ledger.balance("receiver") == Decimal("1.00")


def test_transfer_fee_follows_spec_formula_minimum(context):
    factory, ledger, service = context
    small = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("1.00"), note=None, room_id=None, idempotency_key="t-small", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert small.fee == Decimal("0.01")
    exact = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("2.00"), note=None, room_id=None, idempotency_key="t-exact", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert exact.fee == Decimal("0.01")


def test_transfer_accept_releases_full_amount_to_receiver(context):
    factory, ledger, service = context
    transfer = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("50.00"), note=None, room_id=None, idempotency_key="t2", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    accepted = service.accept(transfer.id, user_id="receiver", idempotency_key="a1")
    assert accepted.status == "ACCEPTED"
    assert ledger.balance("receiver") == Decimal("1.00") + Decimal("50.00")
    assert ledger.balance(f"PLATFORM_TRANSFER_ESCROW:{transfer.id}") == Decimal("0.00")


def test_transfer_decline_refunds_amount_and_fee(context):
    factory, ledger, service = context
    transfer = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("50.00"), note=None, room_id=None, idempotency_key="t3", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    declined = service.decline(transfer.id, user_id="receiver", reason_code="CHAT_TRANSFER_DECLINED", idempotency_key="d1")
    assert declined.status == "DECLINED"
    assert ledger.balance("sender") == Decimal("300.00")
    assert ledger.balance("PLATFORM_FEE") == Decimal("0.00")


def test_transfer_create_insufficient_balance(context):
    factory, ledger, service = context
    with pytest.raises(ValueError, match="insufficient balance"):
        service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("9999.00"), note=None, room_id=None, idempotency_key="t4", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))


def test_transfer_create_is_idempotent(context):
    factory, ledger, service = context
    first = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("10.00"), note="hi", room_id=None, idempotency_key="same", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    again = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("10.00"), note="hi", room_id=None, idempotency_key="same", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert first.id == again.id
    assert ledger.balance("sender") == Decimal("289.95")
    with pytest.raises(ValueError, match="idempotency key reused"):
        service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("20.00"), note="hi", room_id=None, idempotency_key="same", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))


def test_transfer_rejects_self_and_non_positive(context):
    factory, ledger, service = context
    with pytest.raises(ValueError, match="invalid transfer"):
        service.create(sender_id="sender", receiver_id="sender", amount=Decimal("10.00"), note=None, room_id=None, idempotency_key="t5", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    with pytest.raises(ValueError, match="invalid transfer"):
        service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("0.00"), note=None, room_id=None, idempotency_key="t6", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))


def test_transfer_accept_requires_pending_and_receiver(context):
    factory, ledger, service = context
    transfer = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("10.00"), note=None, room_id=None, idempotency_key="t7", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    with pytest.raises(ValueError, match="only the recipient"):
        service.accept(transfer.id, user_id="sender", idempotency_key="a-wrong")
    service.accept(transfer.id, user_id="receiver", idempotency_key="a-ok")
    with pytest.raises(ValueError, match="transfer unavailable"):
        service.accept(transfer.id, user_id="receiver", idempotency_key="a-again")


def test_transfer_expire_refunds_pending_only(context):
    factory, ledger, service = context
    expired = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("10.00"), note=None, room_id=None, idempotency_key="t8", expires_at=datetime.now(timezone.utc) - timedelta(minutes=1))
    pending = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("5.00"), note=None, room_id=None, idempotency_key="t9", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    refunded = service.expire(expired.id, now=datetime.now(timezone.utc), actor_id="worker", idempotency_key=f"expire:{expired.id}")
    assert refunded.status == "EXPIRED"
    assert ledger.balance("sender") == Decimal("294.97")
    with pytest.raises(ValueError, match="has not expired"):
        service.expire(pending.id, now=datetime.now(timezone.utc), actor_id="worker", idempotency_key=f"expire:{pending.id}")


def test_transfer_detail_exposes_participant_safe_fields(context):
    factory, ledger, service = context
    transfer = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("12.00"), note="奶茶", room_id="!room:x", idempotency_key="t10", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    detail = service.detail(transfer.id, user_id="receiver")
    assert detail["amount"] == "12.00"
    assert detail["fee"] == "0.06"
    assert detail["note"] == "奶茶"
    assert detail["status"] == "PENDING"
    assert detail["sender_id"] == "sender"
