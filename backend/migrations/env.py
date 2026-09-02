from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

from app.core.database import Base
from app.core import idempotency as _idempotency  # noqa: F401
from app.core import outbox as _outbox  # noqa: F401
from app.core.migrations import configure_database_url
from app.modules.identity import models as _identity_models  # noqa: F401
from app.modules.audit import models as _audit_models  # noqa: F401
from app.modules.support import service as _support_models  # noqa: F401
from app.modules.ledger import models as _ledger_models  # noqa: F401
from app.modules.ledger import adjustment_models as _adjustment_models  # noqa: F401
from app.modules.redpacket import models as _redpacket_models  # noqa: F401
from app.modules.redpacket import claims as _redpacket_claims  # noqa: F401
from app.modules.wallet import models as _wallet_models  # noqa: F401
from app.modules.friendship import models as _friendship_models  # noqa: F401
from app.modules.moments import models as _moments_models  # noqa: F401
from app.modules.admin import models as _admin_models  # noqa: F401

config = context.config
configure_database_url(config)
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connectable = engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()





