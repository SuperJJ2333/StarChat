"""Read-only dashboard calendar queries."""
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from sqlalchemy import case, func, select

from app.modules.identity.models import User

HONG_KONG = ZoneInfo('Asia/Hong_Kong')


def registration_trend(session, *, days=30, now=None):
    """Count every registration in HK natural days, including unfinished today."""
    if days not in (7, 30, 90):
        raise ValueError('days must be 7, 30 or 90')
    now = now or datetime.now(timezone.utc)
    today = now.astimezone(HONG_KONG).date()
    first = today - timedelta(days=days - 1)
    starts = [datetime.combine(first + timedelta(days=i), time(), HONG_KONG).astimezone(timezone.utc)
              for i in range(days + 1)]
    # Conditional aggregates are portable and return one row, not all users.
    counts = session.execute(select(*[
        func.count(case((User.created_at >= start, 1))).filter(User.created_at < end)
        for start, end in zip(starts, starts[1:])
    ]).where(User.created_at >= starts[0], User.created_at <= now)).one()
    return [{'date': (first + timedelta(days=i)).isoformat(), 'value': count}
            for i, count in enumerate(counts)]
