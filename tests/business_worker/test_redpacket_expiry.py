from datetime import datetime, timedelta, timezone
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parents[2] / "services" / "business-worker" / "app"))
from decimal import Decimal

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.redpacket.service import RedPacketService
from tasks.redpacket_expiry import RedPacketExpiryTask


def test_expiry_task_refunds_due_packets_only():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("5.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="worker-seed")
    now = datetime.now(timezone.utc)
    packets = RedPacketService(factory, ledger)
    due = packets.create_equal(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!due:test", idempotency_key="due", expires_at=now - timedelta(seconds=1))
    future = packets.create_equal(sender_id="sender", total=Decimal("1.00"), share_count=1, room_id="!future:test", idempotency_key="future", expires_at=now + timedelta(hours=1))
    count = RedPacketExpiryTask(factory, packets).run_batch(now=now, limit=10)
    assert count == 1
    with factory() as session:
        assert session.get(type(due), due.id).status == "EXPIRED"
        assert session.get(type(future), future.id).status == "OPEN"
    assert ledger.balance("sender") == Decimal("4.00")
    engine.dispose()

