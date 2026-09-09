from datetime import datetime, timezone
from decimal import Decimal

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.audit.models import AuditEvent


@pytest.fixture
def factory():
    engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool)
    Base.metadata.create_all(engine)
    return create_session_factory(engine)


NOW = datetime(2026, 9, 8, 17, tzinfo=timezone.utc)


def post(session, key, entries, asset='CAIBI', reversal=None, audit=True):
    session.add(LedgerTransaction(id=key, asset=asset, scope='test', idempotency_key=key,
        actor_id='operator', reason_code='TEST', reversal_of_id=reversal, created_at=NOW))
    for i, (account, amount) in enumerate(entries):
        session.add(LedgerEntry(id=f'{key}-{i}', transaction_id=key, account_id=account,
            amount=Decimal(amount), asset=asset, created_at=NOW))
    if audit:
        session.add(AuditEvent(id=f'audit-{key}', actor_id='operator', subject_type='ledger_transaction',
            subject_id=key, action='ledger.post', result='SUCCESS', reason_code='TEST', trace_id='test', created_at=NOW))


def test_registration_hong_kong_day_zero_fill_and_no_limit(factory):
    from app.modules.admin.dashboard_reports import registration_trend
    with factory.begin() as session:
        for i in range(105):
            stamp = datetime(2026, 9, 8, 15, 59, tzinfo=timezone.utc) if i == 0 else datetime(2026, 9, 8, 16, tzinfo=timezone.utc)
            session.add(User(id=str(i), username=str(i), username_normalized=str(i), email=f'{i}@test.invalid',
                email_normalized=f'{i}@test.invalid', password_hash='x', status=AccountStatus.ACTIVE, created_at=stamp, updated_at=stamp))
    with factory() as session:
        rows = registration_trend(session, days=7, now=NOW)
    assert len(rows) == 7
    assert rows[0] == {'date': '2026-09-03', 'value': 0}
    assert rows[-2:] == [{'date': '2026-09-08', 'value': 1}, {'date': '2026-09-09', 'value': 104}]


@pytest.mark.parametrize('days', [7, 30, 90])
def test_registration_empty_window(factory, days):
    from app.modules.admin.dashboard_reports import registration_trend
    with factory() as session:
        rows = registration_trend(session, days=days, now=NOW)
    assert len(rows) == days and all(row['value'] == 0 for row in rows)


def test_supply_clearing_delta_gross_fee_escrow_reversal_and_asset_isolation(factory):
    from app.modules.ledger.supply_reports import point_supply
    with factory.begin() as session:
        post(session, 'issue', [('PLATFORM_CLEARING', '-70'), ('PLATFORM_CLEARING', '-30'), ('u', '100')])
        post(session, 'return', [('PLATFORM_CLEARING', '20'), ('u', '-20')])
        post(session, 'fee', [('u', '-10.05'), ('v', '10'), ('PLATFORM_FEE', '.05')])
        post(session, 'escrow', [('u', '-5'), ('ESCROW_packet', '5')])
        post(session, 'reverse', [('PLATFORM_CLEARING', '10'), ('v', '-10')], reversal='issue')
        post(session, 'usd', [('PLATFORM_CLEARING', '-999'), ('u', '999')], asset='USDT')
    with factory() as session:
        report = point_supply(session, now=NOW)
    assert {key: report[key] for key in ['total', 'issued', 'returned', 'holdings', 'platform_fees']} == {
        'total': '70.00', 'issued': '100.00', 'returned': '30.00', 'holdings': '69.95', 'platform_fees': '0.05'}
    assert report['balanced'] is True


def test_supply_exact_above_javascript_safe_integer(factory):
    from app.modules.ledger.supply_reports import point_supply
    with factory.begin() as session:
        post(session, 'large', [('PLATFORM_CLEARING', '-9007199254740992'), ('u', '9007199254740992')])
        post(session, 'cent', [('PLATFORM_CLEARING', '-.01'), ('u', '.01')])
    with factory() as session:
        assert point_supply(session, now=NOW)['total'] == '9007199254740992.01'


def test_supply_detects_offsetting_bad_transactions_and_missing_reference(factory):
    from app.modules.ledger.supply_reports import point_supply
    with factory.begin() as session:
        post(session, 'bad1', [('PLATFORM_CLEARING', '-1')])
        post(session, 'bad2', [('u', '1')], reversal='missing')
    with factory() as session:
        report = point_supply(session, now=NOW)
    assert report['total'] == report['holdings'] == '1.00'
    assert report['balanced'] is False
    assert report['anomalies']


def test_issuance_pagination_filter_details_and_missing_audit(factory):
    from app.modules.ledger.supply_reports import issuance_page, issuance_detail
    with factory.begin() as session:
        post(session, 'a', [('PLATFORM_CLEARING', '-10'), ('u', '10')])
        post(session, 'b', [('PLATFORM_CLEARING', '2'), ('u', '-2')], reversal='a')
        post(session, 'c', [('u', '-1'), ('v', '1')])
        post(session, 'd', [('PLATFORM_CLEARING', '-5'), ('u', '5')], audit=False)
    with factory() as session:
        first = issuance_page(session, limit=1)
        second = issuance_page(session, limit=1, cursor=first['next_cursor'])
        only_returns = issuance_page(session, kind='returned')
        detail = issuance_detail(session, 'b')
    assert first['items'][0]['id'] == 'd'
    assert first['items'][0]['audit_ids'] == []
    assert first['items'][0]['anomalies'] == ['missing_audit']
    assert second['items'][0]['id'] == 'b'
    assert [item['id'] for item in only_returns['items']] == ['b']
    assert detail['amount'] == '2.00' and detail['reversal_of_id'] == 'a'
    assert detail['audit_ids'] == ['audit-b'] and len(detail['entries']) == 2
    assert detail['audits'][0]['resource_id'] == 'b'
    with factory() as session, pytest.raises(ValueError):
        issuance_page(session, cursor='not-a-cursor')
