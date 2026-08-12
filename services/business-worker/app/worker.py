from collections.abc import Callable, Mapping
from datetime import datetime, timedelta, timezone
from pathlib import Path
from threading import Event
from typing import Any, Protocol


class OutboxConsumerProtocol(Protocol):
    def claim_batch(self, *, worker_id: str, limit: int) -> list[Any]: ...

    def mark_succeeded(self, event_id: str, *, worker_id: str) -> None: ...

    def mark_failed(
        self,
        event_id: str,
        *,
        worker_id: str,
        error: str,
        retry_at: datetime,
    ) -> None: ...


class Worker:
    def __init__(
        self,
        *,
        consumer: OutboxConsumerProtocol,
        handlers: Mapping[str, Callable[[Any], None]],
        worker_id: str,
        retry_delay: timedelta = timedelta(seconds=30),
        now_factory=None,
        heartbeat_path: str | Path | None = None,
        maintenance_tasks: list[Callable[[], Any]] | None = None,
    ) -> None:
        self._consumer = consumer
        self._handlers = dict(handlers)
        self._worker_id = worker_id
        self._retry_delay = retry_delay
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._heartbeat_path = Path(heartbeat_path) if heartbeat_path else None
        self._maintenance_tasks = list(maintenance_tasks or [])

    def run_once(self, limit: int = 50) -> int:
        for task in self._maintenance_tasks:
            task()
        messages = self._consumer.claim_batch(worker_id=self._worker_id, limit=limit)
        for message in messages:
            try:
                handler = self._handlers.get(message.topic)
                if handler is None:
                    raise RuntimeError(f"no handler registered for topic {message.topic}")
                handler(message)
            except Exception as exc:
                self._consumer.mark_failed(
                    message.id,
                    worker_id=self._worker_id,
                    error=str(exc) or exc.__class__.__name__,
                    retry_at=self._now_factory() + self._retry_delay,
                )
            else:
                self._consumer.mark_succeeded(message.id, worker_id=self._worker_id)
        self._touch_heartbeat()
        return len(messages)

    def run_forever(
        self,
        *,
        stop_event: Event,
        poll_interval_seconds: float = 1.0,
        limit: int = 50,
    ) -> None:
        while not stop_event.is_set():
            self.run_once(limit=limit)
            stop_event.wait(poll_interval_seconds)

    def _touch_heartbeat(self) -> None:
        if self._heartbeat_path is None:
            return
        self._heartbeat_path.parent.mkdir(parents=True, exist_ok=True)
        self._heartbeat_path.touch()

