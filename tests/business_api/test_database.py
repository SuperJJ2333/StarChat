import os

import pytest
from sqlalchemy import text

from app.core.database import Base, check_database, create_engine, create_session_factory
from app.core.config import Settings
from app.core.migrations import configure_database_url
from alembic.config import Config


def test_sqlite_engine_and_session_factory() -> None:
    settings = Settings(
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
    )
    engine = create_engine(settings)
    Base.metadata.create_all(engine)
    SessionFactory = create_session_factory(engine)

    with SessionFactory() as session:
        assert session.scalar(text("SELECT 1")) == 1

    assert check_database(engine) is True
    engine.dispose()


def test_alembic_uses_namespaced_business_database_url() -> None:
    config = Config()
    config.set_main_option("sqlalchemy.url", "postgresql://localhost/wrong")

    configure_database_url(
        config,
        {"BUSINESS_DATABASE_URL": "postgresql+psycopg://business-postgres/liuhetong"},
    )

    assert (
        config.get_main_option("sqlalchemy.url")
        == "postgresql+psycopg://business-postgres/liuhetong"
    )


@pytest.mark.skipif(
    os.getenv("RUN_POSTGRES_TESTS") != "1",
    reason="requires an explicitly enabled PostgreSQL integration environment",
)
def test_postgres_database_connectivity() -> None:
    settings = Settings()
    engine = create_engine(settings)
    assert check_database(engine) is True
    engine.dispose()


def test_engine_collects_query_latency_without_sql_or_parameters(tmp_path) -> None:
    settings = Settings(environment="test",
        database_url=f"sqlite+pysqlite:///{tmp_path / 'metrics.db'}",
        redis_url="redis://localhost:6379/15")
    engine = create_engine(settings)
    with engine.connect() as connection:
        connection.execute(text("SELECT :private_value"), {"private_value": "private-token"})
    assert hasattr(engine, "_chatflow_database_metrics")
    snapshot = engine._chatflow_database_metrics.snapshot(engine.pool)
    assert snapshot["query_latency"]["count"] == 1
    assert snapshot["query_latency"]["max_ms"] >= 0
    assert snapshot["query_latency"]["p50_ms"] is not None
    assert "private-token" not in str(snapshot)
    assert "SELECT" not in str(snapshot)
    assert snapshot["pool"]["checked_out"] == 0
    assert snapshot["pool"]["size"] >= 1
    assert snapshot["connection_wait_ms"] is None
    engine.dispose()


def test_db_metrics_window_and_slow_count_are_bounded(tmp_path) -> None:
    settings = Settings(environment="test",
        database_url=f"sqlite+pysqlite:///{tmp_path / 'metrics-window.db'}",
        redis_url="redis://localhost:6379/15")
    engine = create_engine(settings)
    assert hasattr(engine, "_chatflow_database_metrics")
    metrics = engine._chatflow_database_metrics
    for duration_ms in range(1, 601):
        metrics.record_query(float(duration_ms))
    snapshot = metrics.snapshot(engine.pool)
    assert snapshot["query_latency"]["count"] == 512
    assert snapshot["query_latency"]["p50_ms"] == 344
    assert snapshot["query_latency"]["p95_ms"] == 575
    assert snapshot["query_latency"]["p99_ms"] == 595
    assert snapshot["query_latency"]["max_ms"] == 600
    assert snapshot["slow_query_count"] == 501
    engine.dispose()


def test_failed_sql_execution_is_counted_without_statement_text(tmp_path) -> None:
    from sqlalchemy.exc import SQLAlchemyError

    settings = Settings(environment="test",
        database_url=f"sqlite+pysqlite:///{tmp_path / 'failed-query.db'}",
        redis_url="redis://localhost:6379/15")
    engine = create_engine(settings)
    with engine.connect() as connection:
        with pytest.raises(SQLAlchemyError):
            connection.execute(text("SELECT * FROM private_table_does_not_exist"))
        connection.execute(text("SELECT 1"))
    snapshot = engine._chatflow_database_metrics.snapshot(engine.pool)
    assert snapshot["query_latency"]["count"] == 2
    assert "private_table_does_not_exist" not in str(snapshot)
    engine.dispose()
