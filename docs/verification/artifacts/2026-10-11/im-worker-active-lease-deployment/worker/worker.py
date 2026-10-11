import logging
from collections.abc import Callable, Mapping
from datetime import datetime, timedelta, timezone
from math import isfinite
from pathlib import Path
from threading import Event, Thread
from time import monotonic
from typing import Any, Protocol

logger = logging.getLogger("business-worker")

# C02：失败重试采用有界指数退避（30s 起步，封顶 1 小时），
# 超过最大尝试次数进入可审计死信（DEAD），不再占用热队列。
DEFAULT_MAX_ATTEMPTS = 10
BACKOFF_CAP = timedelta(hours=1)
DEFAULT_RENEWAL_INTERVAL_SECONDS = 60.0
DEFAULT_RENEWAL_MAX_SECONDS = 900.0
DEFAULT_RENEWAL_JOIN_SECONDS = 30.0


class LeaseRenewalError(RuntimeError):
    """Ownership is lost/unknown; this Worker must not acknowledge or claim again."""


class _ActiveClaim:
    def __init__(self, renew, *, interval, maximum, join_timeout, clock):
        self._renew = renew
        self._interval = interval
        self._deadline = clock() + maximum
        self._join_timeout = join_timeout
        self._clock = clock
        self._stop = Event()
        self.failure: str | None = None
        # If even bounded driver I/O fails to return, process exit must remain
        # possible. A stopped lifecycle never starts another operation.
        self._thread = Thread(target=self._run, name="outbox-lease", daemon=True)

    def start(self):
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            remaining = self._deadline - self._clock()
            if remaining <= 0:
                self.failure = "renewal_limit"
                return
            if self._stop.wait(min(self._interval, remaining)):
                return
            if self._clock() >= self._deadline:
                self.failure = "renewal_limit"
                return
            try:
                self._renew()
            except BaseException as exc:
                # Do not expose database exception strings/DSNs or payloads.
                self.failure = (
                    "lease_lost" if getattr(exc, "code", None) in {
                        "OUTBOX_LOCK_MISMATCH", "OUTBOX_LEASE_EXPIRED"
                    } else "renewal_unknown"
                )
                return

    def finish(self):
        self._stop.set()
        self._thread.join(self._join_timeout)
        if self._thread.is_alive():
            self.failure = "renewal_unsettled"
        elif self._clock() >= self._deadline:
            self.failure = self.failure or "renewal_limit"
        return self.failure


class OutboxConsumerProtocol(Protocol):
    def claim_batch(self, *, worker_id: str, limit: int, topics: list[str] | None = None) -> list[Any]: ...

    def renew_claim(self, event_id: str, *, worker_id: str, attempt_count: int) -> None: ...

    def mark_claim_succeeded(self, event_id: str, *, worker_id: str, attempt_count: int) -> None: ...

    def mark_claim_failed(
        self,
        event_id: str,
        *,
        worker_id: str,
        attempt_count: int,
        error: str,
        retry_at: datetime,
    ) -> None: ...

    def mark_claim_dead(self, event_id: str, *, worker_id: str, attempt_count: int, error: str) -> None: ...


class MaintenanceHealth:
    """C03：维护任务健康状态——区分"进程活着"与"任务持续失败"。"""

    def __init__(self, name: str) -> None:
        self.name = name
        self.last_success: datetime | None = None
        self.last_failure: datetime | None = None
        self.last_error: str | None = None
        self.consecutive_failures = 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "last_success": self.last_success.isoformat() if self.last_success else None,
            "last_failure": self.last_failure.isoformat() if self.last_failure else None,
            "last_error": self.last_error,
            "consecutive_failures": self.consecutive_failures,
        }


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
        maintenance_interval: timedelta = timedelta(seconds=30),
        max_attempts: int = DEFAULT_MAX_ATTEMPTS,
        reap_undeliverable_age: timedelta | None = None,
        renewal_consumer: OutboxConsumerProtocol | None = None,
        renewal_interval_seconds: float | None = None,
        renewal_max_seconds: float = DEFAULT_RENEWAL_MAX_SECONDS,
        renewal_join_seconds: float = DEFAULT_RENEWAL_JOIN_SECONDS,
        monotonic_factory=monotonic,
    ) -> None:
        for method in ("mark_claim_succeeded", "mark_claim_failed", "mark_claim_dead"):
            if not callable(getattr(consumer, method, None)):
                raise TypeError(f"consumer requires generation-fenced claim completion: {method}")
        self._consumer = consumer
        self._renewal_consumer = renewal_consumer if renewal_consumer is not None else consumer
        if not callable(getattr(self._renewal_consumer, "renew_claim", None)):
            raise TypeError("consumer requires generation-fenced claim renewal: renew_claim")
        self._renewal_interval = (
            DEFAULT_RENEWAL_INTERVAL_SECONDS if renewal_interval_seconds is None
            else renewal_interval_seconds
        )
        if (not all(isfinite(value) for value in (
                self._renewal_interval, renewal_max_seconds, renewal_join_seconds))
                or not (0 < self._renewal_interval < renewal_max_seconds)
                or renewal_join_seconds <= 0):
            raise ValueError("renewal requires positive interval < maximum and positive join budget")
        self._renewal_max = renewal_max_seconds
        self._renewal_join = renewal_join_seconds
        self._monotonic = monotonic_factory
        self._lease_fault: str | None = None
        self._handlers = dict(handlers)
        self._worker_id = worker_id
        self._retry_delay = retry_delay
        self._now_factory = now_factory or (lambda: datetime.now(timezone.utc))
        self._heartbeat_path = Path(heartbeat_path) if heartbeat_path else None
        self._maintenance_interval = maintenance_interval
        self._max_attempts = max(1, int(max_attempts))
        self._reap_undeliverable_age = reap_undeliverable_age
        # C03：每个维护任务独立异常边界/调度周期/健康状态。
        self._maintenance: list[tuple[str, Callable[[], Any], MaintenanceHealth]] = []
        for index, task in enumerate(maintenance_tasks or []):
            self.add_maintenance_task(getattr(task, "__name__", None) or f"maintenance-{index}", task)
        self._maintenance_next_run: dict[str, datetime] = {}

    @property
    def handled_topics(self) -> list[str]:
        """C02：消费者主题契约（与注册 handler 一致）。"""
        return sorted(self._handlers)

    def add_maintenance_task(self, name: str, task: Callable[[], Any]) -> None:
        # Bound methods and lambdas often share a name; schedules must not collide.
        existing = {item[0] for item in self._maintenance}
        unique_name = name
        suffix = 2
        while unique_name in existing:
            unique_name = f"{name}-{suffix}"
            suffix += 1
        self._maintenance.append((unique_name, task, MaintenanceHealth(unique_name)))

    def maintenance_status(self) -> list[dict[str, Any]]:
        return [health.as_dict() for _, _, health in self._maintenance]

    def run_maintenance_once(self) -> None:
        """C03：维护任务逐个隔离执行。

        任一任务抛错只记录健康状态并告警，不影响其他任务，更不会中断
        消息循环；每个任务按 maintenance_interval 独立调度，不再每个
        队列批次都全量执行。
        """
        now = self._now_factory()
        for name, task, health in self._maintenance:
            next_run = self._maintenance_next_run.get(name)
            if next_run is not None and now < next_run:
                continue
            self._maintenance_next_run[name] = now + self._maintenance_interval
            try:
                task()
            except Exception as exc:  # noqa: BLE001 —— 边界隔离，记录后继续
                health.last_failure = now
                health.last_error = str(exc) or exc.__class__.__name__
                health.consecutive_failures += 1
                logger.warning(
                    "maintenance task failed name=%s consecutive=%s error=%s",
                    name,
                    health.consecutive_failures,
                    health.last_error,
                )
            else:
                health.last_success = now
                health.last_error = None
                health.consecutive_failures = 0

    def _reap_undeliverable(self) -> None:
        """C02：无消费者主题进入可审计死信（周期性收割 + 告警）。"""
        reap = getattr(self._consumer, "reap_undeliverable", None)
        if reap is None:
            return
        try:
            count = reap(self.handled_topics, max_age=self._reap_undeliverable_age)
        except Exception as exc:  # noqa: BLE001
            logger.warning("outbox reap failed error=%s", exc)
            return
        if count:
            logger.error(
                "outbox dead-letter: %s events have no registered consumer "
                "(topics contract=%s) — needs operator review/replay",
                count,
                self.handled_topics,
            )

    def run_once(self, limit: int = 50, *, stop_event: Event | None = None) -> int:
        if self._lease_fault is not None:
            raise LeaseRenewalError(self._lease_fault)
        self.run_maintenance_once()
        self._reap_undeliverable()
        processed = 0
        while processed < limit and not (stop_event is not None and stop_event.is_set()):
            # Claim only when ready to dispatch: queued work must not consume
            # its lease while an earlier handler is still running.
            messages = self._consumer.claim_batch(
                worker_id=self._worker_id, limit=1, topics=self.handled_topics
            )
            if not messages:
                break
            message = messages[0]
            lease = _ActiveClaim(
                lambda: self._renewal_consumer.renew_claim(
                    message.id, worker_id=self._worker_id, attempt_count=message.attempt_count
                ),
                interval=self._renewal_interval, maximum=self._renewal_max,
                join_timeout=self._renewal_join, clock=self._monotonic,
            )
            lease.start()
            handler_error = None
            try:
                handler = self._handlers.get(message.topic)
                if handler is None:
                    raise RuntimeError(f"no handler registered for topic {message.topic}")
                handler(message)
            except Exception as exc:
                handler_error = exc
            finally:
                self._lease_fault = lease.finish()
                if self._lease_fault is not None:
                    logger.error("outbox active claim stopped reason=%s", self._lease_fault)
                    raise LeaseRenewalError(self._lease_fault) from None
            if handler_error is not None:
                error = str(handler_error) or handler_error.__class__.__name__
                if message.attempt_count >= self._max_attempts:
                    # 死信终态：保留事件与错误供人工重放。
                    self._consumer.mark_claim_dead(
                        message.id, worker_id=self._worker_id,
                        attempt_count=message.attempt_count, error=error
                    )
                    logger.error(
                        "outbox event dead-lettered id=%s topic=%s attempts=%s error=%s",
                        message.id,
                        message.topic,
                        message.attempt_count,
                        error,
                    )
                else:
                    self._consumer.mark_claim_failed(
                        message.id,
                        worker_id=self._worker_id,
                        attempt_count=message.attempt_count,
                        error=error,
                        retry_at=self._now_factory() + self._retry_backoff(message.attempt_count),
                    )
            else:
                self._consumer.mark_claim_succeeded(
                    message.id, worker_id=self._worker_id, attempt_count=message.attempt_count
                )
            processed += 1
        self._touch_heartbeat()
        return processed

    def _retry_backoff(self, attempt_count: int) -> timedelta:
        # 有界指数退避：30s, 60s, 120s, … 封顶 1 小时。
        doubled = self._retry_delay * (2 ** max(0, attempt_count - 1))
        return min(doubled, BACKOFF_CAP)

    def run_forever(
        self,
        *,
        stop_event: Event,
        poll_interval_seconds: float = 1.0,
        limit: int = 50,
    ) -> None:
        while not stop_event.is_set():
            self.run_once(limit=limit, stop_event=stop_event)
            stop_event.wait(poll_interval_seconds)

    def _touch_heartbeat(self) -> None:
        if self._heartbeat_path is None:
            return
        self._heartbeat_path.parent.mkdir(parents=True, exist_ok=True)
        self._heartbeat_path.touch()
