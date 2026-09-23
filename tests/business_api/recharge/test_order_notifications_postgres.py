"""Run only against a separately-created disposable notification test database."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from app.core.database import Base
from app.core.outbox import OutboxPublisher
from app.modules.recharge.notifications import SupportOrderNotifications
from app.modules.recharge.notification_models import SupportOrderInbox


@pytest.fixture
def database():
    url = os.getenv('STARCHAT_NOTIFICATION_TEST_DATABASE_URL')
    if not url:
        pytest.skip('dedicated notification PostgreSQL database required')
    engine = create_engine(url)
    assert engine.url.database.startswith('support_notifications_'), 'never use a shared database'
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, expire_on_commit=False)
    yield engine, factory
    engine.dispose()


def test_real_transaction_commit_inversion_and_concurrent_delivery(database):
    _, factory = database
    service = SupportOrderNotifications(factory)
    with factory() as early:
        old_id = OutboxPublisher.enqueue(early, topic='recharge', event_type='recharge.submitted',
            aggregate_type='recharge_request', aggregate_id='old-order', payload={},
            now=datetime(2020, 1, 1, tzinfo=timezone.utc))
        early.flush()  # A real uncommitted INSERT, not merely a Python pending row.
        with factory.begin() as later:
            new_id = OutboxPublisher.enqueue(later, topic='recharge', event_type='recharge.claimed',
                aggregate_type='recharge_request', aggregate_id='new-order', payload={},
                now=datetime(2026, 9, 23, tzinfo=timezone.utc))
        first = service.poll(actor_id='pg-staff', limit=1)
        assert [row['id'] for row in first['items']] == [new_id]
        early.commit()
    with ThreadPoolExecutor(max_workers=4) as pool:
        pages = list(pool.map(lambda _: service.poll(actor_id='pg-staff', cursor=first['next_cursor'], limit=1), range(4)))
    assert all(page == pages[0] for page in pages)
    assert [row['id'] for row in pages[0]['items']] == [old_id]
    with factory() as session:
        rows = list(session.scalars(select(SupportOrderInbox).where(SupportOrderInbox.actor_id == 'pg-staff')))
        assert sorted(row.sequence for row in rows) == [1, 2]
        assert {row.event_id for row in rows} == {old_id, new_id}
