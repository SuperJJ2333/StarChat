import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.modules.ledger.models import LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.ledger.statements import StatementService


pytestmark = pytest.mark.skipif(os.getenv("RUN_POSTGRES_TESTS") != "1", reason="requires isolated PostgreSQL")


def test_pg_same_timestamp_keyset_limit_one_has_no_duplicates_or_gaps():
    engine = create_engine(os.environ["AUDIT_PG_URL"])
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    ledger = LedgerService(factory)
    ids = [ledger.adjust(user_id="alice", amount=Decimal("10.00"), actor_id="finance", reason_code=f"SAME_{index}", idempotency_key=f"same-{index}").id for index in range(3)]
    same_time = datetime(2026, 9, 12, 2, 0, tzinfo=timezone(timedelta(hours=8)))
    with factory.begin() as session:
        for row in session.scalars(select(LedgerTransaction).where(LedgerTransaction.id.in_(ids))):
            row.created_at = same_time
    statements = StatementService(factory)
    seen, cursor = [], None
    for _ in range(len(ids) + 1):
        page = statements.list(user_id="alice", limit=1, cursor=cursor)
        seen.extend(item["id"] for item in page["items"])
        cursor = page["next_cursor"]
        if cursor is None:
            break
    assert cursor is None
    assert len(seen) == 3
    assert set(seen) == set(ids)
    engine.dispose()
