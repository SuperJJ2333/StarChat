from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration for the 六合通 business API."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        populate_by_name=True,
    )

    app_name: str = Field(default="六合通 Business API", alias="BUSINESS_APP_NAME")
    environment: Literal["development", "test", "staging", "production"] = Field(
        default="development", alias="BUSINESS_ENVIRONMENT"
    )
    database_url: str = Field(
        default="postgresql+psycopg://liuhetong:liuhetong@localhost:5432/liuhetong",
        alias="BUSINESS_DATABASE_URL",
    )
    redis_url: str = Field(
        default="redis://localhost:6379/1", alias="BUSINESS_REDIS_URL"
    )
    jwt_issuer: str = Field(default="liuhetong", alias="BUSINESS_JWT_ISSUER")
    jwt_secret: str | None = Field(default=None, alias="BUSINESS_JWT_SECRET")
    totp_issuer: str | None = Field(default=None, alias="BUSINESS_TOTP_ISSUER")

    @model_validator(mode="after")
    def validate_production_secrets(self) -> "Settings":
        if self.environment == "production" and (not self.jwt_secret or not self.totp_issuer):
            raise ValueError("production requires BUSINESS_JWT_SECRET and BUSINESS_TOTP_ISSUER")
        return self
