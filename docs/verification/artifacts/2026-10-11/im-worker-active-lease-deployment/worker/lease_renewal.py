"""Dedicated renewal connections; never change the API/handler pool policy."""

from sqlalchemy import create_engine
from sqlalchemy.engine import make_url


def create_renewal_engine(database_url):
    url = make_url(database_url)
    if url.get_backend_name() == "postgresql":
        # Keep caller TLS/routing/options; append timeout policy so URL options
        # cannot silently override the dedicated renewal budget.
        options = url.query.get("options", "")
        return create_engine(
            url, pool_size=1, max_overflow=0, pool_timeout=1,
            connect_args={
                "connect_timeout": 3,
                "options": f"{options} -c statement_timeout=5000 -c lock_timeout=1000 "
                           "-c idle_in_transaction_session_timeout=5000",
                "keepalives": 1, "keepalives_idle": 2,
                "keepalives_interval": 1, "keepalives_count": 3,
                "tcp_user_timeout": 5000,
            },
        )
    if url.get_backend_name() == "sqlite":
        # Local isolated fixtures/development only. Each call still owns a Session.
        return create_engine(url, connect_args={"check_same_thread": False, "timeout": 1})
    raise ValueError("outbox renewal supports PostgreSQL or local SQLite only")
