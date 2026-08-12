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
