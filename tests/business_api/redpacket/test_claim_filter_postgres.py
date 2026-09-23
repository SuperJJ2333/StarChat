"""Requires a task-owned, migrated local PostgreSQL database; never live data."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import os
import time
from threading import Event
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.engine import make_url

from app.core.database import create_session_factory
from app.modules.ledger.models import LedgerEntry
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.claims import RedPacketClaim
from app.modules.redpacket.membership import StaticRoomMembershipAuthority
from app.modules.redpacket.models import RedPacket
from app.modules.redpacket.service import RedPacketService


@pytest.fixture
def pg():
    url = os.environ.get("REDPACKET_QUERY_TEST_DATABASE_URL")
    if not url:
        pytest.skip("isolated redpacket PostgreSQL URL not configured")
    parsed = make_url(url)
    assert parsed.get_backend_name() == "postgresql"
    assert parsed.host in ("127.0.0.1", "localhost")
    assert parsed.database == "redpacket_optimization"
    application_name = "rp-query-" + uuid4().hex
    engine = create_engine(url, pool_size=25, max_overflow=0,
                           connect_args={"options": "-c lock_timeout=1000ms",
                                         "application_name": application_name})
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    sender = str(uuid4())
    users = [str(uuid4()) for _ in range(20)]
    members = StaticRoomMembershipAuthority({"!query:test": {sender, *users}})
    service = RedPacketService(factory, ledger, room_membership=members)
    ledger.adjust(user_id=sender, amount=Decimal("100"), actor_id="test",
                  reason_code="INITIAL_CREDIT", idempotency_key=str(uuid4()))

    def create(shares=1):
        return service.create_equal(sender_id=sender, total=Decimal(shares),
            share_count=shares, room_id="!query:test", idempotency_key=str(uuid4()),
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1))

    yield service, ledger, factory, users, create, engine, application_name
    engine.dispose()


@pytest.mark.parametrize("terminal", ["COMPLETED", "CANCELLED", "EXPIRED", "TIME_EXPIRED"])
def test_unavailable_claim_does_not_wait_for_row_lock(pg, terminal):
    service, ledger, factory, users, create, _, _ = pg
    packet = create()
    if terminal == "COMPLETED":
        service.claim(packet.id, user_id=users[0], idempotency_key=str(uuid4()))
    elif terminal == "CANCELLED":
        service.cancel_unclaimed(packet.id, actor_id="test", reason_code="TEST_CANCEL",
                                 idempotency_key=str(uuid4()))
    elif terminal == "EXPIRED":
        service.expire(packet.id, now=datetime.now(timezone.utc) + timedelta(hours=2),
                       actor_id="test", idempotency_key=str(uuid4()))
    else:
        with factory.begin() as session:
            session.get(RedPacket, packet.id).expires_at = datetime.now(timezone.utc) - timedelta(seconds=1)
    before = ledger.balance(users[1])
    with factory.begin() as blocker:
        blocker.scalar(select(RedPacket).where(RedPacket.id == packet.id).with_for_update())
        with pytest.raises(ValueError, match="red packet unavailable"):
            service.claim(packet.id, user_id=users[1], idempotency_key=str(uuid4()))
    assert ledger.balance(users[1]) == before
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(RedPacketClaim).where(
            RedPacketClaim.packet_id == packet.id)) == (1 if terminal == "COMPLETED" else 0)


def test_concurrent_claims_keep_exact_share_count_and_balanced_ledger(pg):
    service, ledger, factory, users, create, _, _ = pg
    packet = create(3)

    def claim(user):
        try:
            return service.claim(packet.id, user_id=user, idempotency_key=str(uuid4())).amount
        except ValueError as error:
            assert str(error) == "red packet unavailable"
            return Decimal(0)

    with ThreadPoolExecutor(max_workers=20) as executor:
        amounts = list(executor.map(claim, users))
    assert sum(amounts) == Decimal(3)
    assert sum(amount != 0 for amount in amounts) == 3
    assert sum(ledger.balance(user) for user in users) == Decimal(3)
    assert ledger.balance(f"PLATFORM_REDPACKET_ESCROW:{packet.id}") == 0
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(RedPacketClaim).where(
            RedPacketClaim.packet_id == packet.id)) == 3
        assert not session.execute(select(LedgerEntry.transaction_id).group_by(
            LedgerEntry.transaction_id, LedgerEntry.asset).having(func.sum(LedgerEntry.amount) != 0)).all()


def test_waiting_claim_rechecks_state_after_last_share_commits(pg):
    service, ledger, factory, users, create, engine, application_name = pg
    packet = create()
    locked, release = Event(), Event()
    original = service.room_membership.is_member

    def membership(room, user):
        if user == users[0]:
            locked.set()
            assert release.wait(5)
        return original(room, user)

    service.room_membership.is_member = membership
    # Observe the blocked query before releasing the actual final claimant.
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(service.claim, packet.id, user_id=users[0], idempotency_key=str(uuid4()))
        try:
            assert locked.wait(3)
            second = executor.submit(service.claim, packet.id, user_id=users[1], idempotency_key=str(uuid4()))
            deadline = time.monotonic() + .7
            waiting = False
            while time.monotonic() < deadline:
                with engine.connect() as connection:
                    waiting = connection.scalar(text("SELECT EXISTS (SELECT 1 FROM pg_stat_activity "
                        "WHERE application_name=:name AND wait_event_type='Lock')"),
                        {"name": application_name})
                if waiting:
                    break
                time.sleep(.005)
            assert waiting, "second claimant did not reach the row lock"
        finally:
            release.set()
        assert first.result(timeout=3).amount == Decimal(1)
        with pytest.raises(ValueError, match="red packet unavailable"):
            second.result(timeout=3)
    assert ledger.balance(users[1]) == 0
