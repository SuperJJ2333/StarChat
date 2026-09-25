import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.service import LedgerService
from app.modules.ledger.statements import StatementService
from app.modules.transfer.models import ChatTransfer


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


def test_pg_statement_balance_decimal_filters_and_multiple_account_entries():
    engine = create_engine(os.environ["AUDIT_PG_URL"])
    Base.metadata.drop_all(engine)
    # This read projection fixture needs only ledger and transfer tables; do not
    # turn it into a schema/migration test for unrelated lazy-imported modules.
    Base.metadata.create_all(engine, tables=[LedgerTransaction.__table__,
        LedgerEntry.__table__, ChatTransfer.__table__])
    factory = create_session_factory(engine)
    when = datetime(2026, 9, 24, tzinfo=timezone.utc)
    # Deliberately tie timestamps. IDs are the public statement ordering tie-break.
    with factory.begin() as session:
        for tx_id, scope, amounts in [
            ("balance-1", "ledger.adjustment", [Decimal("9007199254740993.01")]),
            ("balance-2", "caibi.transfer", [Decimal("-0.05")]),
            ("balance-3", "caibi.transfer", [Decimal("-10.00"), Decimal("10.00")]),
        ]:
            session.add(LedgerTransaction(id=tx_id, asset="CAIBI", scope=scope,
                idempotency_key=tx_id, actor_id="alice", reason_code="BALANCE_TEST",
                created_at=when))
            session.flush()
            for index, amount in enumerate(amounts):
                session.add(LedgerEntry(id=f"{tx_id}-{index}", transaction_id=tx_id,
                    account_id="alice", asset="CAIBI", amount=amount, created_at=when))
            session.add(LedgerEntry(id=f"{tx_id}-other", transaction_id=tx_id,
                account_id="PLATFORM_CLEARING", asset="CAIBI", amount=-sum(amounts), created_at=when))
    service = StatementService(factory)
    page = service.list(user_id="alice", kind="transfer", limit=1)
    assert page["items"][0]["id"] == "balance-3"
    assert page["items"][0]["amount"] == "0.00"
    assert page["items"][0]["balance_after"] == "9007199254740992.96"
    second = service.list(user_id="alice", kind="transfer", limit=1, cursor=page["next_cursor"])
    assert second["items"][0]["id"] == "balance-2"
    assert second["items"][0]["balance_after"] == "9007199254740992.96"
    assert service.list(user_id="alice", q="balance-2", start_at=when,
        end_at=when + timedelta(days=1))["items"][0]["balance_after"] == "9007199254740992.96"
    assert service.get(user_id="alice", transaction_id="balance-1")["balance_after"] == "9007199254740993.01"
    assert service.list(user_id="mallory")["items"] == []
    engine.dispose()
