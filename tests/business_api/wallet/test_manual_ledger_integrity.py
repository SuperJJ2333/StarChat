from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine, insert, event

from app.core.database import Base, create_session_factory
from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.ledger_integrity import WalletLedgerIntegrityService
from app.modules.wallet.reporting import ReportDataError
# Reporting registers receipt tables; register their FK targets even when this
# module is collected without the full wallet API suite.
from app.modules.wallet import binding_models, funding_models  # noqa: F401

NOW = datetime(2026, 9, 7, tzinfo=timezone.utc)


@pytest.fixture
def db():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    yield create_session_factory(engine), engine
    engine.dispose()


def seed(db, *, entries=2, bad=None):
    factory, engine = db
    with engine.begin() as connection:
        connection.execute(insert(WalletLedgerTransaction), [dict(id=str(i), asset='USDT-TRC20', scope='test',
            idempotency_key=str(i), actor_id='test', reason_code='TEST', created_at=NOW) for i in range((entries+1)//2)])
        for start in range(0, entries, 1000):
            values = [dict(id=str(i), transaction_id=str(i//2), account_id='a' if i%2 else 'b',
                asset='USDT-TRC20', amount=Decimal('1') if i%2 else Decimal('-1'), created_at=NOW)
                for i in range(start, min(start+1000, entries))]
            if bad and start+1000 >= entries: values[-1].update(bad)
            connection.execute(insert(WalletLedgerEntry), values)


def test_more_than_lifetime_report_cap_streamed_one_query(db):
    seed(db, entries=100002)
    calls = []
    event.listen(db[1], 'before_cursor_execute', lambda *a: calls.append(a[2]))
    result = WalletLedgerIntegrityService(db[0]).check(NOW+timedelta(seconds=1))
    assert result == dict(balanced=True, missing_transaction_metadata=False, entry_count=100002)
    assert len(calls) == 1


def test_late_bad_transaction_not_ignored(db):
    seed(db, entries=100002, bad={'amount': Decimal('2')})
    assert not WalletLedgerIntegrityService(db[0]).check(NOW+timedelta(seconds=1))['balanced']


@pytest.mark.parametrize('bad', [{'asset': 'BAD'}, {'amount': Decimal('1.0000001')}])
def test_invalid_stored_evidence_refused(db, bad):
    seed(db, bad=bad)
    with pytest.raises(ReportDataError):
        WalletLedgerIntegrityService(db[0]).check(NOW+timedelta(seconds=1))


def test_offsetting_transactions_and_missing_metadata(db):
    seed(db, entries=4)
    with db[1].begin() as c:
        c.execute(WalletLedgerEntry.__table__.update().where(WalletLedgerEntry.id=='1').values(amount=Decimal('2')))
        c.execute(WalletLedgerEntry.__table__.update().where(WalletLedgerEntry.id=='3').values(amount=Decimal('0')))
    assert not WalletLedgerIntegrityService(db[0]).check(NOW+timedelta(seconds=1))['balanced']
    with db[1].begin() as c:
        c.execute(WalletLedgerTransaction.__table__.delete())
    assert WalletLedgerIntegrityService(db[0]).check(NOW+timedelta(seconds=1))['missing_transaction_metadata']


def test_naive_cutoff_rejected(db):
    with pytest.raises(ValueError): WalletLedgerIntegrityService(db[0]).check(NOW.replace(tzinfo=None))
