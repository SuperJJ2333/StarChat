import os
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timezone
from decimal import Decimal
from unittest.mock import patch
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, func, select, text, update

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.audit.models import AuditEvent
from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction


@pytest.fixture(params=['sqlite'] + (['postgres'] if os.getenv('REPORTING_PG_URL') else []))
def factory(request, tmp_path):
    from app.modules.wallet import closing_models  # noqa: F401
    admin = None
    if request.param == 'postgres':
        schema = 'closing_' + uuid4().hex
        admin = create_engine(os.environ['REPORTING_PG_URL'])
        with admin.begin() as conn:
            conn.execute(text(f'CREATE SCHEMA {schema}'))
        engine = create_engine(os.environ['REPORTING_PG_URL'], connect_args={'options': f'-csearch_path={schema}'})
    else:
        engine = create_engine('sqlite+pysqlite:///' + str(tmp_path / 'close.db'))
    Base.metadata.create_all(engine)
    yield create_session_factory(engine)
    engine.dispose()
    if admin:
        with admin.begin() as conn:
            conn.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        admin.dispose()


def service(factory):
    from app.modules.wallet.closing import WalletClosingService
    return WalletClosingService(factory, now_factory=lambda: datetime(2026, 9, 6, tzinfo=timezone.utc))


def seed(factory, balanced=True):
    at = datetime(2026, 9, 5, tzinfo=timezone.utc)
    ident = str(uuid4())
    with factory.begin() as session:
        session.add(WalletLedgerTransaction(id=ident, asset='USDT-TRC20', scope='test', idempotency_key=ident,
                    actor_id='test', reason_code='TEST', created_at=at))
        session.flush()
        for value in (['1', '-1'] if balanced else ['1']):
            session.add(WalletLedgerEntry(id=str(uuid4()), transaction_id=ident, asset='USDT-TRC20',
                        account_id=value, amount=Decimal(value), created_at=at))


def close(factory, key='key', day=date(2026, 9, 5), actor='finance', reason='DAILY_CLOSE'):
    return service(factory).close(day, actor, reason, key)


def test_restart_replay_and_late_revision_remain_immutable(factory):
    seed(factory)
    first = close(factory)
    assert first['revision'] == 1 and first['previous_id'] is None
    assert first['cutoff_kind'] == 'CAPTURED_ENTRY_SET'
    assert first['report']['finalized'] is False
    seed(factory)
    assert service(factory).get(first['id']) == first
    assert close(factory) == first
    second = close(factory, 'new')
    assert second['revision'] == 2 and second['previous_id'] == first['id']
    assert second['digest'] != first['digest']
    assert service(factory).get(first['id']) == first
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.action == 'wallet.daily_closed')) == 2
        events = session.scalars(select(OutboxEvent).where(OutboxEvent.event_type == 'wallet.daily_closed')).all()
        assert len(events) == 2
        assert {event.aggregate_id for event in events} == {first['id'], second['id']}
        assert all(event.payload == {'id': event.aggregate_id, 'reason_code': 'DAILY_CLOSE'} for event in events)


@pytest.mark.parametrize('kwargs', [{'day': date(2026, 9, 4)}, {'actor': 'other'}, {'reason': 'OTHER'}])
def test_key_payload_collision(factory, kwargs):
    close(factory)
    with pytest.raises(AppError) as error:
        close(factory, **kwargs)
    assert error.value.status_code == 409


@pytest.mark.parametrize('day', [date(2026, 9, 6), date(2026, 9, 7)])
def test_reject_open_days(factory, day):
    with pytest.raises(ValueError):
        close(factory, day=day)


def test_refuse_unbalanced_capture_and_tampered_storage(factory):
    from app.modules.wallet.closing_models import WalletDailyClose
    first = close(factory)
    with factory.begin() as session:
        payload = dict(first['report'], finalized=True)
        session.execute(update(WalletDailyClose).where(WalletDailyClose.id == first['id']).values(report=payload))
    with pytest.raises(AppError) as error:
        service(factory).get(first['id'])
    assert error.value.status_code == 409
    seed(factory, balanced=False)
    with pytest.raises(AppError):
        close(factory, 'bad')


def test_concurrent_revisions_and_replay(factory):
    seed(factory)
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda key: close(factory, key), ['a', 'b', 'a', 'c']))
    assert results[0] == results[2]
    unique = {row['id']: row for row in results}
    ordered = sorted(unique.values(), key=lambda row: row['revision'])
    assert [row['revision'] for row in ordered] == [1, 2, 3]
    assert [row['previous_id'] for row in ordered] == [None, ordered[0]['id'], ordered[1]['id']]


def test_outbox_failure_rolls_back_close_and_audit(factory):
    from app.modules.wallet.closing_models import WalletDailyClose
    with patch('app.modules.wallet.safety.OutboxPublisher.enqueue', side_effect=RuntimeError('injected outbox failure')):
        with pytest.raises(RuntimeError, match='injected outbox failure'):
            close(factory)
    with factory() as session:
        for model in (WalletDailyClose, AuditEvent, OutboxEvent):
            assert session.scalar(select(func.count()).select_from(model)) == 0
    assert close(factory)['revision'] == 1


def test_get_missing_close(factory):
    with pytest.raises(AppError) as error:
        service(factory).get(str(uuid4()))
    assert error.value.status_code == 404
