import csv
import os
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from io import StringIO
from unittest.mock import patch
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, event, text
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.ledger.service import LedgerService
from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.service import WalletLedger


@pytest.fixture(params=['sqlite'] + (['postgres'] if os.getenv('REPORTING_PG_URL') else []))
def factory(request):
    admin = None
    if request.param == 'postgres':
        schema = 'reporting_' + uuid4().hex
        admin = create_engine(os.environ['REPORTING_PG_URL'])
        with admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA {schema}'))
        engine = create_engine(os.environ['REPORTING_PG_URL'], connect_args={'options': f'-csearch_path={schema}'})
    else:
        engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool)
    Base.metadata.create_all(engine)
    yield create_session_factory(engine)
    engine.dispose()
    if admin is not None:
        with admin.begin() as connection:
            connection.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


def post(factory, entries, at, *, caibi=False, key='seed'):
    module = 'app.modules.ledger.service' if caibi else 'app.modules.wallet.service'
    service = LedgerService(factory) if caibi else WalletLedger(factory)
    with patch(module + '.datetime') as clock:
        clock.now.return_value = at
        return service.post(entries={k: Decimal(v) for k, v in entries.items()},
                            actor_id='test', reason_code='REPORT_TEST',
                            idempotency_key=key, scope='report.test')


def test_daily_boundaries_all_accounts_precision_and_single_snapshot(factory):
    from app.modules.wallet.reporting import WalletReportService
    start = datetime(2026, 9, 4, 16, tzinfo=timezone.utc)
    post(factory, {'alice': '10', 'PLATFORM_CUSTODY': '-10'}, start-timedelta(seconds=1))
    post(factory, {'alice': '2.000001', 'PLATFORM_CUSTODY': '-2.000001'}, start, key='start')
    post(factory, {'alice': '-1', 'held:alice': '1'}, start+timedelta(hours=1), key='held')
    post(factory, {'alice': '5', 'PLATFORM_CUSTODY': '-5'}, start+timedelta(days=1), key='end')
    post(factory, {'=SUM(1,1)': '0.01', 'PLATFORM_CLEARING': '-0.01'}, start, caibi=True)
    statements = []
    def capture(conn, cursor, statement, parameters, context, executemany):
        statements.append(statement)
    event.listen(factory.kw['bind'], 'before_cursor_execute', capture)
    report = WalletReportService(factory).daily(date(2026, 9, 5))
    event.remove(factory.kw['bind'], 'before_cursor_execute', capture)
    assert len(statements) == 1 and 'UNION ALL' in statements[0]
    assert report['start'] == '2026-09-04T16:00:00Z'
    assert report['end'] == '2026-09-05T16:00:00Z'
    assert report['finalized'] is False
    accounts = {(a['asset'], a['account']): a for a in report['accounts']}
    assert accounts['USDT-TRC20', 'alice'] == dict(asset='USDT-TRC20', account='alice', opening='10.000000', increase='2.000001', decrease='1.000000', closing='11.000001')
    assert accounts['USDT-TRC20', 'held:alice']['closing'] == '1.000000'
    assert accounts['CAIBI', 'PLATFORM_CLEARING']['closing'] == '-0.01'
    assert report['integrity']['balanced'] is True
    assert len(report['entries']) == 8
    assert WalletReportService(factory).daily(date(2026, 9, 5)) == report
    for account in report['accounts']:
        assert Decimal(account['opening']) + Decimal(account['increase']) - Decimal(account['decrease']) == Decimal(account['closing'])


def test_offsetting_corrupt_transactions_cannot_hide(factory):
    from app.modules.wallet.reporting import WalletReportService
    at = datetime(2026, 9, 5, tzinfo=timezone.utc)
    with factory.begin() as session:
        for index, value in enumerate(['1', '-1']):
            txid = f'corrupt-{index}'
            session.add(WalletLedgerTransaction(id=txid, asset='USDT-TRC20', scope='test', idempotency_key=txid, actor_id='test', reason_code='CORRUPT_FIXTURE', created_at=at))
            session.flush()
            session.add(WalletLedgerEntry(id=txid, transaction_id=txid, asset='USDT-TRC20', account_id='alice', amount=Decimal(value), created_at=at))
    integrity = WalletReportService(factory).daily(date(2026, 9, 5))['integrity']
    assert integrity['balanced'] is False
    assert len(integrity['imbalances']) == 2


def test_evidence_cap_and_date_validation(factory):
    from app.modules.wallet.reporting import WalletReportService
    post(factory, {'alice': '1', 'PLATFORM_CUSTODY': '-1'}, datetime(2026, 9, 5, tzinfo=timezone.utc))
    with pytest.raises(OverflowError):
        WalletReportService(factory, max_entries=1).daily(date(2026, 9, 5))
    for limit in [0, 100001, True, 1.5]:
        with pytest.raises(ValueError):
            WalletReportService(factory, max_entries=limit)
    for day in ['2026-09-05', date(9999, 1, 1), datetime.now()]:
        with pytest.raises(ValueError):
            WalletReportService(factory).daily(day)


def test_csv_neutralizes_strings_preserves_money_and_digest(factory):
    from app.modules.wallet.reporting import WalletReportService, to_csv
    at = datetime(2026, 9, 5, tzinfo=timezone.utc)
    post(factory, {'=SUM(1,1)': '1', 'PLATFORM_CUSTODY': '-1'}, at)
    report = WalletReportService(factory).daily(date(2026, 9, 5))
    exported = list(csv.reader(StringIO(to_csv(report))))
    cells = [cell for row in exported for cell in row]
    assert "'=SUM(1,1)" in cells
    assert '=SUM(1,1)' not in cells
    assert '-1.000000' in cells
    assert report['digest'] in cells
    before = report['digest']
    post(factory, {'alice': '0.000001', 'PLATFORM_CUSTODY': '-0.000001'}, at, key='late')
    assert WalletReportService(factory).daily(date(2026, 9, 5))['digest'] != before


@pytest.mark.parametrize('account', ['+cmd', '-cmd', '@SUM(A1)', '\tformula', '\rformula', '\nformula', '  =1+1'])
def test_csv_control_and_whitespace_prefixes(factory, account):
    from app.modules.wallet.reporting import WalletReportService, to_csv
    post(factory, {account: '1', 'PLATFORM_CUSTODY': '-1'}, datetime(2026, 9, 5, tzinfo=timezone.utc))
    cells = [cell for row in csv.reader(StringIO(to_csv(WalletReportService(factory).daily(date(2026, 9, 5))))) for cell in row]
    assert "'" + account in cells
    assert account not in cells


def test_aggregation_uses_large_decimal_context():
    from app.modules.wallet.reporting import WalletReportService
    at = datetime(2026, 9, 5, tzinfo=timezone.utc)
    rows = [dict(source='wallet', id=str(index), transaction_id='large', account='large', asset='USDT-TRC20',
                 amount='999999999999999999999999.000001', created_at=at, reason_code='TEST', scope='test')
            for index in range(10)]
    # Exercise public daily with a captured exact database projection, independent
    # of SQLite's underlying NUMERIC storage limit.
    from unittest.mock import MagicMock
    factory = MagicMock()
    factory.return_value.__enter__.return_value.execute.return_value.mappings.return_value.all.return_value = rows
    report = WalletReportService(factory).daily(date(2026, 9, 5))
    assert report['accounts'][0]['closing'] == '9999999999999999999999990.000010'


@pytest.mark.parametrize('asset,amount', [('BTC', '1'), ('USDT-TRC20', 'NaN'), ('USDT-TRC20', 'Infinity'), ('USDT-TRC20', '0.0000001'), ('CAIBI', '0.001')])
def test_invalid_stored_evidence_is_not_rounded(asset, amount):
    from app.modules.wallet.reporting import ReportDataError, WalletReportService
    from unittest.mock import MagicMock
    factory = MagicMock()
    factory.return_value.__enter__.return_value.execute.return_value.mappings.return_value.all.return_value = [
        dict(source='wallet', id='bad', transaction_id='bad', account='bad', asset=asset,
             amount=amount, created_at=datetime(2026, 9, 5, tzinfo=timezone.utc), reason_code='TEST', scope='test')]
    with pytest.raises(ReportDataError):
        WalletReportService(factory).daily(date(2026, 9, 5))


def test_postgres_exact_numeric_storage(factory):
    if factory.kw['bind'].dialect.name != 'postgresql':
        return
    from app.modules.wallet.reporting import WalletReportService
    at = datetime(2026, 9, 5, tzinfo=timezone.utc)
    amount = Decimal('999999999999999999999999.000001')
    with factory.begin() as session:
        session.add(WalletLedgerTransaction(id='large', asset='USDT-TRC20', scope='test', idempotency_key='large', actor_id='test', reason_code='NUMERIC_FIXTURE', created_at=at))
        session.flush()
        for entry_id, value in [('positive', amount), ('negative', amount.copy_negate())]:
            session.add(WalletLedgerEntry(id=entry_id, transaction_id='large', asset='USDT-TRC20', account_id=entry_id, amount=value, created_at=at))
    report = WalletReportService(factory).daily(date(2026, 9, 5))
    assert report['integrity']['balanced'] is True
    assert {a['closing'] for a in report['accounts']} == {'999999999999999999999999.000001', '-999999999999999999999999.000001'}
