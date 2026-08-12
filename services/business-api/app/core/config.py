from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the 六合通 business API."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        env_prefix="BUSINESS_",
        extra="ignore",
        populate_by_name=True,
    )

    app_name: str = "六合通 Business API"
    environment: Literal["development", "test", "staging", "production"] = "development"
    database_url: str = "postgresql+psycopg://liuhetong:liuhetong@localhost:5432/liuhetong"
    redis_url: str = "redis://localhost:6379/1"
    jwt_issuer: str = "liuhetong"
    jwt_secret: str | None = None
    totp_issuer: str | None = None

    @model_validator(mode="after")
    def validate_production_secrets(self) -> "Settings":
        if self.environment == "production" and (not self.jwt_secret or not self.totp_issuer):
            raise ValueError("production requires BUSINESS_JWT_SECRET and BUSINESS_TOTP_ISSUER")
        return self
