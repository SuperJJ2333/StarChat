"""Bounded read-only user projections for authorized administrator modules."""
import base64
import binascii
import hashlib
import json
from datetime import datetime, timezone

from sqlalchemy import and_, func, or_, select

from app.modules.identity.models import User


def utc_text(value):
    if value is None:
        return None
    # SQLite drops timezone metadata; stored identity timestamps are UTC.
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def _decode_cursor(cursor, query):
    try:
        value = json.loads(base64.b64decode(cursor.encode('ascii'), altchars=b'-_', validate=True))
        if not isinstance(value, list) or len(value) != 3:
            raise ValueError('cursor shape')
        timestamp, key, search = value
        stamp = datetime.fromisoformat(timestamp)
        if (stamp.tzinfo is None or stamp.utcoffset() is None or search != _search_digest(query)
                or not isinstance(key, str) or not 1 <= len(key) <= 36):
            raise ValueError('cursor values')
        return stamp.astimezone(timezone.utc), key
    except (ValueError, TypeError, UnicodeError, binascii.Error, OverflowError) as exc:
        raise ValueError('invalid user cursor') from exc


def _search_digest(query):
    # Bind pagination to its filter without copying email searches into tokens.
    return hashlib.sha256(query.encode('utf-8')).hexdigest()


def user_page(session, *, q=None, limit=100, cursor=None):
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError('invalid user page limit')
    if q is not None and (not isinstance(q, str) or len(q) > 128):
        raise ValueError('invalid user search')
    if cursor is not None and (not isinstance(cursor, str) or not 1 <= len(cursor) <= 1024):
        raise ValueError('invalid user cursor')
    query = (q or '').strip().casefold()
    filters = []
    if query:
        literal = query.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
        pattern = '%'+literal+'%'
        filters.append(or_(User.username_normalized.ilike(pattern, escape='\\'),
            User.nickname.ilike(pattern, escape='\\'), User.email_normalized.ilike(pattern, escape='\\')))
    total = session.scalar(select(func.count()).select_from(User).where(*filters))
    # Select only safe display columns; neither password hashes nor email leave this query.
    statement = select(User.id, User.username, User.nickname, User.status,
        User.created_at, User.updated_at, User.email_verified_at).where(*filters)
    if cursor:
        stamp, key = _decode_cursor(cursor, query)
        statement = statement.where(or_(User.created_at < stamp,
            and_(User.created_at == stamp, User.id < key)))
    rows = session.execute(statement.order_by(User.created_at.desc(), User.id.desc()).limit(limit+1)).all()
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit-1]
        next_cursor = base64.urlsafe_b64encode(json.dumps([utc_text(last.created_at), last.id, _search_digest(query)]).encode()).decode()
    return {'items': [{'id': row.id, 'username': row.username, 'nickname': row.nickname,
        'status': row.status.value, 'created_at': utc_text(row.created_at),
        'updated_at': utc_text(row.updated_at), 'email_verified_at': utc_text(row.email_verified_at)}
        for row in rows[:limit]], 'total': total, 'next_cursor': next_cursor}
