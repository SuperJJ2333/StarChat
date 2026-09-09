"""Pair serialization shared by new creation claims and legacy registration."""
from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert as postgres_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from app.modules.friendship.models import DirectRoomReservation


def lock_pair(session, actor, peer, attempt_id):
    """Insert before reading: SQLite obtains its write lock; PG locks the row.

    ON CONFLICT avoids a uniqueness exception/savepoint aborting the outer
    transaction. The returned inserted flag is the only creation authorization.
    All callers hold this pair lock through canonical-room publication/commit.
    """
    low, high = sorted((actor, peer))
    dialect = session.get_bind().dialect.name
    insert = {'postgresql': postgres_insert, 'sqlite': sqlite_insert}.get(dialect)
    if insert is None:
        raise RuntimeError('Direct-room coordination requires PostgreSQL or SQLite')
    row_id = str(uuid4())
    statement = insert(DirectRoomReservation).values(
        id=row_id, user_low_id=low, user_high_id=high, owner_id=actor,
        attempt_id=attempt_id, created_at=datetime.now(timezone.utc),
    ).on_conflict_do_nothing(index_elements=['user_low_id', 'user_high_id'])
    session.execute(statement)
    row = session.scalar(select(DirectRoomReservation).where(
        DirectRoomReservation.user_low_id == low,
        DirectRoomReservation.user_high_id == high,
    ).with_for_update())
    return row, row.id == row_id
