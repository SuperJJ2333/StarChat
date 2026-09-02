from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[2] / "services" / "business-worker" / "app"))

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.transfer.service import ChatTransferService
from tasks.chat_transfer_expiry import ChatTransferExpiryTask


def test_transfer_expiry_task_refunds_due_transfers_only():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ledger.adjust(user_id="sender", amount=Decimal("5.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="worker-seed")
    now = datetime.now(timezone.utc)
    service = ChatTransferService(factory, ledger)
    due = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("1.00"), note=None, room_id=None, idempotency_key="due", expires_at=now - timedelta(seconds=1))
    future = service.create(sender_id="sender", receiver_id="receiver", amount=Decimal("1.00"), note=None, room_id=None, idempotency_key="future", expires_at=now + timedelta(hours=1))
    count = ChatTransferExpiryTask(factory, service).run_batch(now=now, limit=10)
    assert count == 1
    with factory() as session:
        assert session.get(type(due), due.id).status == "EXPIRED"
        assert session.get(type(future), future.id).status == "PENDING"
    assert ledger.balance("sender") == Decimal("5.00") - Decimal("1.01")
    engine.dispose()
