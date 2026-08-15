from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from app.modules.audit.models import AuditEvent


_SECRET_KEYS = {
    "password",
    "password_hash",
    "token",
    "access_token",
    "refresh_token",
    "totp_secret",
    "encrypted_secret",
    "authorization",
    "room_key",
    "message_plaintext",
}


def redact_metadata(value: Any, key: str | None = None) -> Any:
    if key is not None and key.casefold() in _SECRET_KEYS:
        return "[REDACTED]"
    if isinstance(value, dict):
        return {str(k): redact_metadata(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact_metadata(item) for item in value]
    return value


class AuditWriter:
    def __init__(self, session_factory, now_factory=None) -> None:
        self._session_factory = session_factory
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def record(
        self,
        *,
        actor_id: str | None,
        subject_type: str,
        subject_id: str,
        action: str,
        result: str,
        reason_code: str,
        trace_id: str,
        source_ip: str | None = None,
        source_device_id: str | None = None,
        before: dict[str, Any] | None = None,
        after: dict[str, Any] | None = None,
    ) -> str:
        with self._session_factory.begin() as session:
            return self.record_in_session(
                session,
                actor_id=actor_id,
                subject_type=subject_type,
                subject_id=subject_id,
                action=action,
                result=result,
                reason_code=reason_code,
                trace_id=trace_id,
                source_ip=source_ip,
                source_device_id=source_device_id,
                before=before,
                after=after,
            )

    def record_in_session(
        self,
        session,
        *,
        actor_id: str | None,
        subject_type: str,
        subject_id: str,
        action: str,
        result: str,
        reason_code: str,
        trace_id: str,
        source_ip: str | None = None,
        source_device_id: str | None = None,
        before: dict[str, Any] | None = None,
        after: dict[str, Any] | None = None,
    ) -> str:
        event_id = str(uuid4())
        session.add(
            AuditEvent(
                id=event_id,
                actor_id=actor_id,
                subject_type=subject_type,
                subject_id=subject_id,
                action=action,
                result=result,
                reason_code=reason_code,
                trace_id=trace_id,
                source_ip=source_ip,
                source_device_id=source_device_id,
                before_data=redact_metadata(before) if before is not None else None,
                after_data=redact_metadata(after) if after is not None else None,
                created_at=self._now_factory(),
            )
        )
        return event_id
