from datetime import datetime, timezone
from typing import Any
import re
from uuid import UUID, uuid4, uuid5

from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.modules.audit.models import AuditEvent


INTERNAL_PUBLICATION_TOPICS = frozenset(
    {
        "admin",
        "friendship.events",
        "identity",
        "identity.staff",
        "identity.wallet_access",
        "ledger",
        "moments",
        "moments.events",
        "recharge",
        "wallet",
        "wallet.incident",
    }
)
# Versioned consumer identity. The payload digest deliberately does not select
# another receipt identity: changed envelopes must conflict with the old receipt.
_PUBLICATION_NAMESPACE = UUID("ad998a6d-c4d2-5a1f-a965-af0a4bbc2386")


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

    def record_internal_publication(
        self, *, event_id: str, topic: str, event_type: str, envelope_sha256: str
    ) -> str:
        """Commit one immutable internal receipt independently of Outbox ACK.

        This records internal publication only; it never delivers a notification
        or applies the business event a second time.
        """
        try:
            valid_id = isinstance(event_id, str) and str(UUID(event_id)) == event_id
        except (ValueError, TypeError, AttributeError):
            valid_id = False
        if (
            not valid_id
            or not isinstance(topic, str)
            or topic not in INTERNAL_PUBLICATION_TOPICS
            or not isinstance(event_type, str)
            or re.fullmatch(r"[a-z][a-z0-9_.]{0,99}", event_type) is None
            or not isinstance(envelope_sha256, str)
            or re.fullmatch(r"[0-9a-f]{64}", envelope_sha256) is None
        ):
            raise ValueError("INVALID_INTERNAL_PUBLICATION")
        receipt_id = str(uuid5(_PUBLICATION_NAMESPACE, event_id))
        stable = {
            "actor_id": None,
            "subject_type": "outbox_event",
            "subject_id": event_id,
            "action": "outbox.internal_published",
            "result": "ACCEPTED",
            "reason_code": "INTERNAL_PUBLICATION_V1",
            "trace_id": event_id,
            "source_ip": None,
            "source_device_id": None,
            "before_data": None,
            "after_data": {
                "receipt_version": 1,
                "topic": topic,
                "event_type": event_type,
                "envelope_sha256": envelope_sha256,
            },
        }

        def same(actual, expected):
            if type(actual) is not type(expected):
                return False
            if isinstance(expected, dict):
                return set(actual) == set(expected) and all(
                    same(actual[key], value) for key, value in expected.items()
                )
            return actual == expected

        def match(existing):
            if any(
                not same(getattr(existing, field), value)
                for field, value in stable.items()
            ):
                raise ValueError("INTERNAL_PUBLICATION_CONFLICT")

        try:
            try:
                with self._session_factory.begin() as session:
                    existing = session.get(AuditEvent, receipt_id)
                    if existing is not None:
                        match(existing)
                    else:
                        session.add(
                            AuditEvent(
                                id=receipt_id, created_at=self._now_factory(), **stable
                            )
                        )
                        session.flush()
            except IntegrityError:
                # A simultaneous insert can win after our SELECT. Query only
                # after the failed transaction rolled back, and validate it.
                with self._session_factory.begin() as session:
                    existing = session.get(AuditEvent, receipt_id)
                    if existing is None:
                        raise RuntimeError(
                            "INTERNAL_PUBLICATION_STORAGE_FAILURE"
                        ) from None
                    match(existing)
        except SQLAlchemyError:
            # Worker stores exception text. Do not expose SQL parameters/payload.
            raise RuntimeError("INTERNAL_PUBLICATION_STORAGE_FAILURE") from None
        return receipt_id

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
