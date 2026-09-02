from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService

@pytest.fixture()
def services():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("100.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed-red")
    yield RedPacketService(factory, ledger), ledger
    engine.dispose()

def test_equal_group_red_packet_claim_and_expire_refund(services):
    service, ledger = services
    packet = service.create_equal(sender_id="sender", total=Decimal("10.00"), share_count=3, room_id="!room:test", idempotency_key="rp-equal", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert [share.amount for share in packet.shares] == [Decimal("3.34"), Decimal("3.33"), Decimal("3.33")]
    claimed = service.claim(packet.id, user_id="alice", idempotency_key="claim-a")
    assert claimed.amount == Decimal("3.34")
    service.expire(packet.id, now=datetime.now(timezone.utc) + timedelta(hours=25), actor_id="worker", idempotency_key="expire-a")
    assert ledger.balance("alice") == Decimal("3.34")
    assert ledger.balance("sender") == Decimal("96.66")

def test_random_packet_sums_exactly_and_user_claims_once(services):
    service, _ = services
    packet = service.create_random(sender_id="sender", total=Decimal("8.88"), share_count=8, recipient_id="friend", idempotency_key="rp-random", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    assert sum((share.amount for share in packet.shares), Decimal("0.00")) == Decimal("8.88")
    assert all(share.amount >= Decimal("0.01") for share in packet.shares)
    service.claim(packet.id, user_id="friend", idempotency_key="claim-1")
    with pytest.raises(ValueError, match="already claimed"):
        service.claim(packet.id, user_id="friend", idempotency_key="claim-2")

def test_authorized_cancel_refunds_only_unclaimed(services):
    service, ledger = services
    packet = service.create_equal(sender_id="sender", total=Decimal("2.00"), share_count=2, room_id="!room:test", idempotency_key="rp-cancel", expires_at=datetime.now(timezone.utc) + timedelta(hours=24))
    service.claim(packet.id, user_id="alice", idempotency_key="claim-cancel")
    service.cancel_unclaimed(packet.id, actor_id="supervisor", reason_code="ABNORMAL_RED_PACKET", idempotency_key="cancel-1")
    assert ledger.balance("sender") == Decimal("99.00")
    assert ledger.balance("alice") == Decimal("1.00")
