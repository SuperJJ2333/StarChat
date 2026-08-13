from datetime import datetime, timezone

from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.moments.models import Moment
from tasks.moments import MomentsModerationTask


def test_moments_worker_rejects_unsafe_media_and_keeps_safe_posts():
    engine = create_engine('sqlite+pysqlite:///:memory:', connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add_all([
            Moment(id='safe', author_id='u', text='ok', visibility='PUBLIC', image_urls=['https://cdn.test/a.jpg'], include_user_ids=[], exclude_user_ids=[], status='PENDING_REVIEW', idempotency_key='safe', created_at=now),
            Moment(id='bad', author_id='u', text='bad', visibility='PUBLIC', image_urls=['https://cdn.test/a.exe'], include_user_ids=[], exclude_user_ids=[], status='PENDING_REVIEW', idempotency_key='bad', created_at=now),
        ])
    result = MomentsModerationTask(factory).run_batch(limit=10)
    assert result == {'published': 1, 'rejected': 1}
    with factory() as session:
        assert session.get(Moment, 'safe').status == 'PUBLISHED'
        assert session.get(Moment, 'bad').status == 'REJECTED'
