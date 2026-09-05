from typing import Literal

from pydantic import field_validator, model_validator
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
    adjustment_admin_threshold: str = "10000.00"
    red_packet_max_total: str = "20000.00"
    wallet_webhook_secret: str | None = None
    # A04：托管模式门禁——生产启用资金功能必须显式 production provider
    # （真实实现未接入前生产资金入口关闭，绝不回退沙箱）。
    wallet_custody_provider: Literal["sandbox", "production"] = "sandbox"
    # U03：充值确认阈值（客户端展示与服务端判定同一来源）。
    wallet_confirmation_threshold: int = 12
    email_verification_secret: str | None = None
    password_reset_secret: str | None = None
    matrix_homeserver_url: str = "http://synapse:8008"
    matrix_public_homeserver_url: str = "http://localhost:8008"
    matrix_server_name: str = "matrix.localhost"
    synapse_admin_access_token: str | None = None
    matrix_provision_secret: str | None = None
    matrix_login_token_expires_in: Literal[60] = 60
    avatar_storage_root: str = "/data/private-media"
    avatar_url_signing_secret: str | None = None
    avatar_public_base_url: str = "http://localhost:8082"
    referral_code_secret: str | None = None
    referral_rotation_seconds: int = 1800
    referral_share_base_url: str = "https://liuhetong888.com/register"
    referral_reward_enabled: bool = False
    # 统一邀请码（规格 §6.2）：用户固定个人注册邀请码的次数与滚动有效期。
    personal_invite_max_uses: int = 20
    personal_invite_expiry_days: int = 365
    media_max_upload_bytes: int = 10 * 1024 * 1024

    @field_validator("matrix_login_token_expires_in", mode="before")
    @classmethod
    def parse_matrix_login_token_expiry(cls, value):
        return int(value) if isinstance(value, str) else value

    @model_validator(mode="after")
    def validate_production_secrets(self) -> "Settings":
        if self.environment != "production":
            return self
        secret_values = (
            self.jwt_secret,
            self.email_verification_secret,
            self.password_reset_secret,
            self.synapse_admin_access_token,
            self.matrix_provision_secret,
            self.avatar_url_signing_secret,
            self.referral_code_secret,
        )
        unsafe_prefixes = ("change-this", "development-")
        if (
            not self.totp_issuer
            or any(not value for value in secret_values)
            or any(
                value.strip().casefold().startswith(unsafe_prefixes)
                for value in secret_values
                if value
            )
        ):
            raise ValueError(
                "production requires non-placeholder production secrets: "
                "BUSINESS_JWT_SECRET, BUSINESS_TOTP_ISSUER, "
                "BUSINESS_EMAIL_VERIFICATION_SECRET, BUSINESS_PASSWORD_RESET_SECRET "
                "BUSINESS_SYNAPSE_ADMIN_ACCESS_TOKEN, BUSINESS_MATRIX_PROVISION_SECRET, "
                "BUSINESS_AVATAR_URL_SIGNING_SECRET and BUSINESS_REFERRAL_CODE_SECRET"
            )
        if not self.matrix_public_homeserver_url.startswith("https://") or not self.avatar_public_base_url.startswith("https://"):
            raise ValueError("production public Matrix and avatar URLs must use HTTPS")
        # A04：生产启用钱包资金功能时，回调签名密钥为必填且不得是占位值。
        if self.wallet_custody_provider == "production":
            wallet_secret = self.wallet_webhook_secret
            if (
                not wallet_secret
                or wallet_secret.strip().casefold().startswith(unsafe_prefixes)
            ):
                raise ValueError(
                    "production wallet provider requires a non-placeholder "
                    "BUSINESS_WALLET_WEBHOOK_SECRET"
                )
        return self



