from collections.abc import Mapping
import os

from alembic.config import Config


def configure_database_url(
    config: Config, environment: Mapping[str, str] | None = None
) -> None:
    values = environment if environment is not None else os.environ
    database_url = values.get("BUSINESS_DATABASE_URL")
    if database_url:
        config.set_main_option("sqlalchemy.url", database_url.replace("%", "%%"))
