import os
from collections.abc import Callable

from sqlalchemy import Engine, create_engine as sqlalchemy_create_engine, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.core.config import Settings


class Base(DeclarativeBase):
    """Base class for immutable-ledger and business domain models."""


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
    return sqlalchemy_create_engine(settings.database_url, **kwargs)


def create_session_factory(engine: Engine) -> Callable[[], Session]:
    return sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def check_database(engine: Engine) -> bool:
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return True
    except Exception:
        return False
