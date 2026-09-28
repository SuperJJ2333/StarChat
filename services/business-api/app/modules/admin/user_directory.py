"""Restricted directory projection; intentionally separate from redacted reports."""
import base64
import binascii
import hashlib
import hmac
import json
from datetime import datetime, timezone

from sqlalchemy import and_, func, or_, select

from app.modules.admin.user_reports import utc_text
from app.modules.identity.models import User
from app.modules.ledger.service import LedgerService
from app.modules.support.service import SupportQueueService


class UserDirectoryService:
    def __init__(self, session_factory, *, cursor_secret: str):
        self.session_factory = session_factory
        self.cursor_key = cursor_secret.encode("utf-8")
        self.ledger = LedgerService(session_factory)
        self.support = SupportQueueService(session_factory)

    def _cursor_signature(self, query: str, timestamp: str, key: str) -> str:
        # Authenticate the complete page boundary without exposing short searches.
        payload = json.dumps([query, timestamp, key], separators=(",", ":"),
            ensure_ascii=False).encode("utf-8")
        return hmac.new(self.cursor_key,
            b"admin-user-directory:cursor:v2:\0" + payload, hashlib.sha256).hexdigest()

    def _decode_cursor(self, cursor: str, query: str) -> tuple[datetime, str]:
        try:
            value = json.loads(base64.b64decode(cursor.encode("ascii"),
                altchars=b"-_", validate=True))
            if not isinstance(value, list) or len(value) != 3:
                raise ValueError("cursor shape")
            timestamp, key, digest = value
            stamp = datetime.fromisoformat(timestamp)
            if (stamp.tzinfo is None or stamp.utcoffset() is None
                    or not isinstance(key, str) or not 1 <= len(key) <= 36
                    or not isinstance(digest, str)
                    or not hmac.compare_digest(digest,
                        self._cursor_signature(query, timestamp, key))):
                raise ValueError("cursor values")
            return stamp.astimezone(timezone.utc), key
        except (ValueError, TypeError, UnicodeError, binascii.Error, OverflowError) as exc:
            raise ValueError("invalid directory cursor") from exc

    def search(self, *, q: str | None = None, limit: int = 50,
               cursor: str | None = None) -> dict:
        if q is not None and (not isinstance(q, str) or len(q) > 128):
            raise ValueError("invalid directory search")
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError("invalid directory limit")
        if cursor is not None and (not isinstance(cursor, str) or not 1 <= len(cursor) <= 1024):
            raise ValueError("invalid directory cursor")
        query = (q or "").strip().casefold()
        filters = []
        if query:
            literal = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            pattern = f"%{literal}%"
            filters.append(or_(
                User.username_normalized.ilike(pattern, escape="\\"),
                User.nickname.ilike(pattern, escape="\\"),
                User.email_normalized.ilike(pattern, escape="\\"),
                User.phone_normalized.ilike(pattern, escape="\\"),
            ))
        with self.session_factory() as session:
            total = session.scalar(select(func.count()).select_from(User).where(*filters)) or 0
            # Explicit columns keep password, Matrix and wallet data out of this read.
            statement = select(User.id, User.username, User.nickname, User.status,
                User.email, User.email_verified_at, User.phone, User.phone_verified_at,
                User.created_at).where(*filters)
            if cursor is not None:
                stamp, key = self._decode_cursor(cursor, query)
                statement = statement.where(or_(User.created_at < stamp,
                    and_(User.created_at == stamp, User.id < key)))
            rows = session.execute(statement.order_by(User.created_at.desc(), User.id.desc())
                .limit(limit + 1)).all()
        page = rows[:limit]
        next_cursor = None
        if len(rows) > limit:
            last = page[-1]
            timestamp = utc_text(last.created_at)
            next_cursor = base64.urlsafe_b64encode(json.dumps([
                timestamp, last.id, self._cursor_signature(query, timestamp, last.id)],
                separators=(",", ":")).encode()).decode()
        ids = [row.id for row in page]
        balances = self.ledger.balances_for(ids)
        titles = self.support.official_titles_for(ids)
        return {
            "items": [{
                "id": row.id, "username": row.username, "nickname": row.nickname,
                "status": row.status.value, "email": row.email,
                "email_verified_at": utc_text(row.email_verified_at),
                "phone": row.phone, "phone_verified_at": utc_text(row.phone_verified_at),
                "caibi_balance": f"{balances[row.id]:.2f}",
                "official_support_title": titles.get(row.id),
            } for row in page],
            "total": total,
            "next_cursor": next_cursor,
        }
