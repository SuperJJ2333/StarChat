"""Database setup and bounded, SQL-free execution diagnostics."""

import os
from collections import deque
from collections.abc import Callable
from math import ceil
from threading import Lock
from time import perf_counter

from sqlalchemy import Engine, create_engine as sqlalchemy_create_engine, event, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.core.config import Settings


SLOW_QUERY_THRESHOLD_MS = 100.0
_QUERY_START_KEY = "_chatflow_perf_query_starts"


class Base(DeclarativeBase):
    """Base class for immutable-ledger and business domain models."""


class DatabasePerformanceMetrics:
    """Execution-only SQL timing; connection acquisition and row fetch are excluded."""

    def __init__(self, *, sample_capacity: int = 512,
                 slow_query_threshold_ms: float = SLOW_QUERY_THRESHOLD_MS) -> None:
        if sample_capacity < 1:
            raise ValueError("sample capacity must be positive")
        self._samples: deque[float] = deque(maxlen=sample_capacity)
        self._slow_query_count = 0
        self._slow_threshold_ms = slow_query_threshold_ms
        self._lock = Lock()

    def record_query(self, duration_ms: float) -> None:
        with self._lock:
            self._samples.append(max(0.0, duration_ms))
            if duration_ms >= self._slow_threshold_ms:
                self._slow_query_count += 1

    def snapshot(self, pool) -> dict:
        with self._lock:
            ordered = sorted(self._samples)
            slow_query_count = self._slow_query_count
        count = len(ordered)

        def percentile(percent: float) -> float | None:
            return ordered[ceil(count * percent) - 1] if count else None

        def pool_value(name: str) -> int | None:
            probe = getattr(pool, name, None)
            if not callable(probe):
                return None
            try:
                return int(probe())
            except (AttributeError, NotImplementedError, TypeError):
                return None

        return {
            "query_latency": {
                "count": count,
                "p50_ms": percentile(0.50),
                "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99),
                "max_ms": ordered[-1] if count else None,
            },
            "slow_query_count": slow_query_count,
            "pool": {
                "size": pool_value("size"),
                "checked_in": pool_value("checkedin"),
                "checked_out": pool_value("checkedout"),
                "overflow": pool_value("overflow"),
            },
            # QueuePool checkout callbacks fire *after* any wait. No supported
            # hook here brackets the wait, so report it as unavailable.
            "connection_wait_ms": None,
        }


def _install_database_metrics(engine: Engine) -> None:
    metrics = DatabasePerformanceMetrics()
    engine._chatflow_database_metrics = metrics

    @event.listens_for(engine, "before_cursor_execute")
    def before_execute(conn, cursor, statement, parameters, context, executemany):
        conn.info.setdefault(_QUERY_START_KEY, []).append(perf_counter())

    def finish_execute(conn) -> None:
        starts = conn.info.get(_QUERY_START_KEY)
        if not starts:
            return
        started = starts.pop()
        metrics.record_query((perf_counter() - started) * 1000.0)

    @event.listens_for(engine, "after_cursor_execute")
    def after_execute(conn, cursor, statement, parameters, context, executemany):
        finish_execute(conn)

    @event.listens_for(engine, "handle_error")
    def on_error(exception_context):
        connection = exception_context.connection
        if connection is not None:
            finish_execute(connection)


def create_engine(settings: Settings) -> Engine:
    kwargs: dict[str, object] = {
        "pool_pre_ping": True,
        # 连接池容量：默认 SQLAlchemy 池(5+10)撑不住多 worker 并发；
        # 上限需与 Postgres max_connections 预算对齐（见 docker-compose）。
        "pool_size": int(os.environ.get("DB_POOL_SIZE", "10")),
        "max_overflow": int(os.environ.get("DB_MAX_OVERFLOW", "15")),
        "pool_timeout": int(os.environ.get("DB_POOL_TIMEOUT", "30")),
        "pool_recycle": 1800,
    }
    if settings.database_url.startswith("sqlite"):
        kwargs = {"connect_args": {"check_same_thread": False}}
    engine = sqlalchemy_create_engine(settings.database_url, **kwargs)
    _install_database_metrics(engine)
    return engine


def create_session_factory(engine: Engine) -> Callable[[], Session]:
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def check_database(engine: Engine) -> bool:
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return True
    except Exception:
        return False
