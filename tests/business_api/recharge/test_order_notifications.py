from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxPublisher
from app.modules.recharge.notifications import SupportOrderNotifications
from app.modules.recharge.notification_models import SupportOrderInbox


@pytest.fixture
def inbox(tmp_path):
    engine = create_engine('sqlite:///' + str(tmp_path / 'notifications.db'),
                           connect_args={'check_same_thread': False, 'timeout': 10})
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    yield SupportOrderNotifications(factory), factory
    engine.dispose()


def enqueue(factory, *, age=0, topic='recharge', event_type='recharge.submitted',
            aggregate_type='recharge_request', order='order-1'):
    with factory.begin() as session:
        return OutboxPublisher.enqueue(session, topic=topic, event_type=event_type,
            aggregate_type=aggregate_type, aggregate_id=order,
            payload={'request_id': order, 'secret': 'must-not-leak'},
            now=datetime(2026, 9, 23, tzinfo=timezone.utc) + timedelta(seconds=age))


def test_late_commit_older_than_delivered_cursor_is_not_lost(inbox):
    service, factory = inbox
    newer = enqueue(factory, age=100)
    first = service.poll(actor_id='staff-1', limit=1)
    assert [item['id'] for item in first['items']] == [newer]
    older = enqueue(factory, age=-100)
    second = service.poll(actor_id='staff-1', cursor=first['next_cursor'], limit=1)
    assert [item['id'] for item in second['items']] == [older]
    assert 'secret' not in str(second)
    assert service.poll(actor_id='staff-1', cursor=second['next_cursor'])['items'] == []


def test_lost_response_retry_pages_and_restart_are_stable(inbox):
    service, factory = inbox
    ids = [enqueue(factory, age=i, order=f'order-{i}') for i in range(5)]
    first = service.poll(actor_id='staff-1', limit=2)
    assert service.poll(actor_id='staff-1', limit=2) == first
    service = SupportOrderNotifications(factory)
    second = service.poll(actor_id='staff-1', cursor=first['next_cursor'], limit=2)
    assert service.poll(actor_id='staff-1', cursor=first['next_cursor'], limit=2) == second
    third = service.poll(actor_id='staff-1', cursor=second['next_cursor'], limit=2)
    assert [row['id'] for page in [first, second, third] for row in page['items']] == ids
    assert service.poll(actor_id='staff-2', limit=2)['items'] == first['items']
    with pytest.raises(AppError) as error:
        service.poll(actor_id='staff-2', cursor=first['next_cursor'])
    assert error.value.code == 'RECHARGE_CURSOR_INVALID'


def test_actual_wallet_topic_included_but_quotes_directory_other_money_excluded(inbox):
    service, factory = inbox
    wanted = enqueue(factory, topic='wallet', event_type='wallet.manual_payout_request', aggregate_type='wallet')
    enqueue(factory, topic='wallet', event_type='wallet.manual_payout_quote', aggregate_type='wallet')
    enqueue(factory, topic='wallet', event_type='wallet.withdrawal', aggregate_type='wallet')
    enqueue(factory, topic='wallet', event_type='wallet.support_payout_heartbeat', aggregate_type='wallet')
    enqueue(factory, event_type='recharge.directory_updated', aggregate_type='recharge_directory')
    result = service.poll(actor_id='staff-1')
    assert [row['id'] for row in result['items']] == [wanted]
    assert result['items'][0]['kind'] == 'payout'


@pytest.mark.parametrize('event_type', ['wallet.manual_payout_support_claim', 'wallet.manual_payout_support_review_claim', 'wallet.support_payout_started', 'wallet.support_payout_expired'])
def test_support_payout_coordination_events_are_not_missed(inbox, event_type):
    service, factory = inbox
    identity = enqueue(factory, topic='wallet', event_type=event_type, aggregate_type='wallet')
    assert [row['id'] for row in service.poll(actor_id='staff-1')['items']] == [identity]


def test_concurrent_polls_have_one_committed_sequence_and_same_page(inbox):
    service, factory = inbox
    for i in range(4):
        enqueue(factory, age=i)
    with ThreadPoolExecutor(max_workers=4) as pool:
        pages = list(pool.map(lambda _: service.poll(actor_id='staff-1', limit=2), range(4)))
    assert all(page == pages[0] for page in pages)
    with factory() as session:
        rows = list(session.scalars(select(SupportOrderInbox).where(SupportOrderInbox.actor_id == 'staff-1')))
        assert len({row.event_id for row in rows}) == len(rows)
        assert len({row.sequence for row in rows}) == len(rows)


def test_uncommitted_event_is_invisible_then_delivered_without_skipping(inbox):
    service, factory = inbox
    first = enqueue(factory, age=100)
    with factory() as transaction:
        late = OutboxPublisher.enqueue(transaction, topic='recharge', event_type='recharge.claimed',
            aggregate_type='recharge_request', aggregate_id='late', payload={},
            now=datetime(2020, 1, 1, tzinfo=timezone.utc))
        page = service.poll(actor_id='staff-1')
        assert [item['id'] for item in page['items']] == [first]
        transaction.commit()
    result = service.poll(actor_id='staff-1', cursor=page['next_cursor'])
    assert [item['id'] for item in result['items']] == [late]


@pytest.mark.parametrize('cursor', ['garbage', '2026-09-23|old-id', ''])
def test_invalid_cursor_fails_closed(inbox, cursor):
    service, _ = inbox
    with pytest.raises(AppError):
        service.poll(actor_id='staff-1', cursor=cursor)
