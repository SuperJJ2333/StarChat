from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from sqlalchemy import JSON, DateTime, String, UniqueConstraint, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.database import Base
from app.core.errors import AppError


class IdempotencyRecord(Base):
    __tablename__ = "idempotency_records"
    __table_args__ = (
        UniqueConstraint("scope", "idempotency_key", name="uq_idempotency_scope_key"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    scope: Mapped[str] = mapped_column(String(100), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(128), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    response_status: Mapped[int | None]
    response_body: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


@dataclass(frozen=True)
class IdempotencyResult:
    replay: bool
    response_status: int | None = None
    response_body: dict[str, Any] | None = None


class IdempotencyService:
    def __init__(self, session_factory) -> None:
        self._session_factory = session_factory

    def begin(self, scope: str, key: str, request_hash: str) -> IdempotencyResult:
        with self._session_factory() as session:
            record = self._find(session, scope, key)
            if record is None:
                record = IdempotencyRecord(
                    id=str(uuid4()),
                    scope=scope,
                    idempotency_key=key,
                    request_hash=request_hash,
                    status="IN_PROGRESS",
                    created_at=datetime.now(timezone.utc),
                )
                session.add(record)
                try:
                    session.commit()
                    return IdempotencyResult(replay=False)
                except IntegrityError:
                    session.rollback()
                    record = self._find(session, scope, key)

            if record is None:
                raise RuntimeError("idempotency record disappeared after uniqueness conflict")
            self._ensure_same_hash(record, request_hash)
            if record.status == "COMPLETED":
                return IdempotencyResult(
                    replay=True,
                    response_status=record.response_status,
                    response_body=record.response_body,
                )
            raise AppError(
                code="IDEMPOTENCY_IN_PROGRESS",
                message="idempotency request is already in progress",
                status_code=409,
            )

    def complete(
        self,
        scope: str,
        key: str,
        request_hash: str,
        *,
        response_status: int,
        response_body: dict[str, Any],
    ) -> IdempotencyResult:
        with self._session_factory() as session:
            record = self._find(session, scope, key)
            if record is None:
                raise AppError(
                    code="IDEMPOTENCY_NOT_FOUND",
                    message="idempotency request was not started",
                    status_code=409,
                )
            self._ensure_same_hash(record, request_hash)
            if record.status != "COMPLETED":
                record.status = "COMPLETED"
                record.response_status = response_status
                record.response_body = response_body
                record.completed_at = datetime.now(timezone.utc)
                session.commit()
            return IdempotencyResult(
                replay=True,
                response_status=record.response_status,
                response_body=record.response_body,
            )

    @staticmethod
    def _find(session: Session, scope: str, key: str) -> IdempotencyRecord | None:
        return session.scalar(
            select(IdempotencyRecord).where(
                IdempotencyRecord.scope == scope,
                IdempotencyRecord.idempotency_key == key,
            )
        )

    @staticmethod
    def _ensure_same_hash(record: IdempotencyRecord, request_hash: str) -> None:
        if record.request_hash != request_hash:
            raise AppError(
                code="IDEMPOTENCY_KEY_REUSED",
                message="idempotency key was reused with a different request hash",
                status_code=409,
            )
