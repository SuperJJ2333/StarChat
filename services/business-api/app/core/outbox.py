from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import uuid4

from sqlalchemy import JSON, DateTime, Index, Integer, String, Text, and_, func, or_, select
from sqlalchemy.orm import Mapped, Session, mapped_column

from app.core.database import Base
from app.core.errors import AppError
from app.core.outbox_handover_models import OutboxHandoverDisposition  # noqa: F401


class OutboxEvent(Base):
    __tablename__ = "outbox_events"
    __table_args__ = (
        Index("ix_outbox_claim", "status", "available_at", "created_at"),
    )

    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    topic: Mapped[str] = mapped_column(String(100), nullable=False)
    event_type: Mapped[str] = mapped_column(String(100), nullable=False)
    aggregate_type: Mapped[str] = mapped_column(String(100), nullable=False)
    aggregate_id: Mapped[str] = mapped_column(String(128), nullable=False)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    event_headers: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False, default=dict)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    attempt_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    available_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    locked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    locked_by: Mapped[str | None] = mapped_column(String(100))
    last_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    published_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


@dataclass(frozen=True)
class OutboxMessage:
    id: str
    topic: str
    event_type: str
    aggregate_type: str
    aggregate_id: str
    payload: dict[str, Any]
    headers: dict[str, Any]
    attempt_count: int


class OutboxPublisher:
    @staticmethod
    def enqueue(
        session: Session,
        *,
        topic: str,
        event_type: str,
        aggregate_type: str,
        aggregate_id: str,
        payload: dict[str, Any],
        headers: dict[str, Any] | None = None,
        now: datetime | None = None,
    ) -> str:
        event_id = str(uuid4())
        created_at = now or datetime.now(timezone.utc)
        session.add(
            OutboxEvent(
                id=event_id,
                topic=topic,
                event_type=event_type,
                aggregate_type=aggregate_type,
                aggregate_id=aggregate_id,
                payload=payload,
                event_headers=headers or {},
                status="PENDING",
                attempt_count=0,
                available_at=created_at,
                created_at=created_at,
            )
        )
        return event_id


class OutboxConsumer:
    def __init__(
        self,
        session_factory,
        now_factory=None,
        lease_timeout: timedelta = timedelta(minutes=5),
        wallet_handover_preparation_mode: bool = False,
    ) -> None:
        self._session_factory = session_factory
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._database_lease_clock = now_factory is None
        self._lease_timeout = lease_timeout
        self._wallet_handover_preparation_mode = wallet_handover_preparation_mode

    def claim_batch(self, *, worker_id: str, limit: int, topics: list[str] | None = None) -> list[OutboxMessage]:
        """领取待处理事件。

        C02：`topics` 为该消费者声明的处理契约——只领取已注册 handler 的
        主题，未知主题不占用热队列（由 reap_undeliverable 进入可审计
        死信流程）。
        """
        if limit < 1:
            return []
        from app.core.outbox_handover import OutboxHandover, SUMMARY_EVENT
        with self._session_factory.begin() as session:
            now = self._lease_now(session)
            stale_before = now - self._lease_timeout
            statement = (
                select(OutboxEvent)
                .where(
                    OutboxHandover.not_superseded_predicate(),
                    or_(
                        and_(
                            OutboxEvent.status.in_(("PENDING", "FAILED")),
                            OutboxEvent.available_at <= now,
                        ),
                        and_(
                            OutboxEvent.status == "PROCESSING",
                            OutboxEvent.locked_at <= stale_before,
                        ),
                    ),
                )
                .order_by(OutboxEvent.created_at, OutboxEvent.id)
                .limit(limit)
                .with_for_update(skip_locked=True)
            )
            if topics is not None:
                statement = statement.where(OutboxEvent.topic.in_(topics))
            if self._wallet_handover_preparation_mode:
                statement = statement.where(or_(OutboxEvent.topic != 'wallet.alert', OutboxEvent.event_type == SUMMARY_EVENT))
            events = list(session.scalars(statement))
            for event in events:
                event.status = "PROCESSING"
                event.locked_at = now
                event.locked_by = worker_id
                event.attempt_count += 1
            return [self._to_message(event) for event in events]

    def mark_succeeded(self, event_id: str, *, worker_id: str) -> None:
        """Legacy owner-only completion; new workers must use mark_claim_succeeded."""
        now = self._now_factory()
        with self._session_factory.begin() as session:
            event = self._locked_event(session, event_id, worker_id)
            event.status = "PUBLISHED"
            event.published_at = now
            event.locked_at = None
            event.locked_by = None
            event.last_error = None

    def mark_failed(
        self,
        event_id: str,
        *,
        worker_id: str,
        error: str,
        retry_at: datetime,
    ) -> None:
        """Legacy owner-only completion; new workers must use mark_claim_failed."""
        with self._session_factory.begin() as session:
            event = self._locked_event(session, event_id, worker_id)
            event.status = "FAILED"
            event.available_at = retry_at
            event.locked_at = None
            event.locked_by = None
            event.last_error = error[:4000]

    def mark_dead(self, event_id: str, *, worker_id: str, error: str) -> None:
        """Legacy owner-only completion; new workers must use mark_claim_dead."""
        with self._session_factory.begin() as session:
            event = self._locked_event(session, event_id, worker_id)
            event.status = "DEAD"
            event.locked_at = None
            event.locked_by = None
            event.last_error = error[:4000]

    def renew_claim(self, event_id: str, *, worker_id: str, attempt_count: int) -> None:
        """Renew only a live generation; DB/lock failures propagate to the caller.

        This does not fence handler side effects or start a renewal lifecycle.
        Sample time after acquiring the lock so an expired claim cannot revive.
        """
        with self._session_factory.begin() as session:
            event = self._claimed_event(session, event_id, worker_id, attempt_count, nowait=True)
            now = self._lease_now(session)
            locked_at = event.locked_at
            if locked_at is not None and locked_at.tzinfo is None:
                locked_at = locked_at.replace(tzinfo=timezone.utc)
            if locked_at is None or locked_at <= now - self._lease_timeout:
                raise AppError(
                    code="OUTBOX_LEASE_EXPIRED",
                    message="outbox claim lease has expired",
                    status_code=409,
                )
            event.locked_at = now

    def _lease_now(self, session: Session) -> datetime:
        # A single authority for default production lease decisions, independent
        # of worker host clock skew. Explicit fixture clocks remain supported.
        if self._database_lease_clock and session.get_bind().dialect.name == "postgresql":
            return session.scalar(select(func.clock_timestamp()))
        return self._now_factory()

    def mark_claim_succeeded(self, event_id: str, *, worker_id: str, attempt_count: int) -> None:
        """Complete this generation, including expired claims not yet reclaimed."""
        with self._session_factory.begin() as session:
            event = self._claimed_event(session, event_id, worker_id, attempt_count)
            event.status = "PUBLISHED"
            event.published_at = self._now_factory()
            event.locked_at = None
            event.locked_by = None
            event.last_error = None

    def mark_claim_failed(
        self, event_id: str, *, worker_id: str, attempt_count: int,
        error: str, retry_at: datetime,
    ) -> None:
        with self._session_factory.begin() as session:
            event = self._claimed_event(session, event_id, worker_id, attempt_count)
            event.status = "FAILED"
            event.available_at = retry_at
            event.locked_at = None
            event.locked_by = None
            event.last_error = error[:4000]

    def mark_claim_dead(
        self, event_id: str, *, worker_id: str, attempt_count: int, error: str,
    ) -> None:
        with self._session_factory.begin() as session:
            event = self._claimed_event(session, event_id, worker_id, attempt_count)
            event.status = "DEAD"
            event.locked_at = None
            event.locked_by = None
            event.last_error = error[:4000]

    def reap_undeliverable(self, handled_topics: list[str], *, max_age: timedelta | None = None) -> int:
        """C02：把无消费者的主题移入可审计死信（DEAD）。

        只处理超过 max_age 的事件——给"新代码已发布、新消费者尚未上线"
        的部署错位留出宽限窗口。返回本次收割数量（调用方据此告警）。
        人工重放：将 status 重置 PENDING 即可（事件本体未删除）。
        """
        now = self._now_factory()
        from app.core.outbox_handover import OutboxHandover
        cutoff = now - (max_age if max_age is not None else timedelta(minutes=10))
        with self._session_factory.begin() as session:
            events = list(
                session.scalars(
                    select(OutboxEvent)
                    .where(
                        OutboxHandover.not_superseded_predicate(),
                        or_(not self._wallet_handover_preparation_mode,
                            OutboxEvent.topic != 'wallet.alert',
                            OutboxEvent.event_type == 'wallet.handover.summary'),
                        OutboxEvent.status.in_(("PENDING", "FAILED")),
                        OutboxEvent.topic.not_in(handled_topics),
                        OutboxEvent.created_at <= cutoff,
                    )
                    .with_for_update(skip_locked=True)
                )
            )
            for event in events:
                event.status = "DEAD"
                event.last_error = f"no registered consumer for topic {event.topic}"
                event.locked_at = None
                event.locked_by = None
            return len(events)

    @staticmethod
    def _claimed_event(
        session: Session, event_id: str, worker_id: str, attempt_count: int,
        *, nowait: bool = False,
    ) -> OutboxEvent:
        if type(attempt_count) is not int or attempt_count < 1:
            raise ValueError("attempt_count must be a positive integer from the original claim")
        event = session.scalar(
            select(OutboxEvent)
            .where(
                OutboxEvent.id == event_id,
                OutboxEvent.status == "PROCESSING",
                OutboxEvent.locked_by == worker_id,
                OutboxEvent.attempt_count == attempt_count,
            )
            .with_for_update(nowait=nowait)
        )
        if event is None:
            raise AppError(
                code="OUTBOX_LOCK_MISMATCH",
                message="outbox event is not locked by this worker and claim generation",
                status_code=409,
            )
        return event

    @staticmethod
    def _locked_event(session: Session, event_id: str, worker_id: str) -> OutboxEvent:
        event = session.scalar(
            select(OutboxEvent)
            .where(
                OutboxEvent.id == event_id,
                OutboxEvent.status == "PROCESSING",
                OutboxEvent.locked_by == worker_id,
            )
            .with_for_update()
        )
        if event is None:
            raise AppError(
                code="OUTBOX_LOCK_MISMATCH",
                message="outbox event is not locked by this worker",
                status_code=409,
            )
        return event

    @staticmethod
    def _to_message(event: OutboxEvent) -> OutboxMessage:
        return OutboxMessage(
            id=event.id,
            topic=event.topic,
            event_type=event.event_type,
            aggregate_type=event.aggregate_type,
            aggregate_id=event.aggregate_id,
            payload=event.payload,
            headers=event.event_headers,
            attempt_count=event.attempt_count,
        )
