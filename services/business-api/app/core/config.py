from typing import Literal
from datetime import datetime
from decimal import Decimal
import re

from pydantic import SecretStr, field_validator, model_validator
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
    # Compatibility rollout only: configured accounts always require a PIN.
    payment_pin_require_all: bool = False
    totp_issuer: str | None = None
    wallet_totp_encryption_key: SecretStr | None = None

    @field_validator('wallet_totp_encryption_key')
    @classmethod
    def validate_wallet_totp_key(cls, value):
        if value is not None:
            from cryptography.fernet import Fernet
            try:
                Fernet(value.get_secret_value().encode('ascii'))
            except (ValueError, UnicodeError):
                raise ValueError('wallet TOTP requires a valid Fernet key') from None
        return value

    @model_validator(mode='after')
    def validate_wallet_totp_issuer(self):
        if self.wallet_totp_encryption_key is not None and not (self.totp_issuer or '').strip():
            raise ValueError('wallet TOTP requires an issuer')
        return self
    adjustment_admin_threshold: str = "10000.00"
    red_packet_max_total: str = "20000.00"
    wallet_webhook_secret: str | None = None
    # A04：托管模式门禁——生产启用资金功能必须显式 production provider
    # （真实实现未接入前生产资金入口关闭，绝不回退沙箱）。
    wallet_custody_provider: Literal["sandbox", "production"] = "sandbox"
    # U03：充值确认阈值（客户端展示与服务端判定同一来源）。
    wallet_confirmation_threshold: int = 20
    wallet_conversions_enabled: bool = False
    wallet_sandbox_store_path: str | None = None
    tron_observer_database_path: str | None = None
    wallet_binding_domain: str | None = None
    wallet_real_mode: Literal['disabled', 'manual_tron'] = 'disabled'
    wallet_user_auth_mode: Literal['wallet_proof', 'address_only'] = 'wallet_proof'
    wallet_real_funds_enabled: bool = False
    wallet_deposits_enabled: bool | None = None
    wallet_payout_requests_enabled: bool | None = None
    wallet_payout_execution_enabled: bool | None = None
    wallet_reserve_policy: Literal['full_backing', 'manual_liquidity'] = 'full_backing'
    wallet_handover_deployment_record_path: str | None = None
    wallet_handover_preparation_mode: bool = False
    wallet_trongrid_api_key: SecretStr | None = None
    wallet_official_address: SecretStr | None = None
    wallet_official_config_version: str | None = None
    wallet_manual_owner_admin_id: str | None = None
    wallet_admin_auth_mode: Literal['totp', 'operation_password'] = 'totp'
    wallet_manual_policy_version: str | None = None
    wallet_manual_max_per: str | None = None
    wallet_manual_user_24h: str | None = None
    wallet_manual_global_24h: str | None = None
    wallet_manual_quote_ttl_seconds: int = 300
    wallet_manual_stale_resample_budget_seconds: int = 60

    @field_validator('wallet_manual_stale_resample_budget_seconds', mode='before')
    @classmethod
    def validate_manual_stale_resample_budget(cls, value):
        if isinstance(value, str) and re.fullmatch(r'[0-9]+', value):
            value = int(value)
        if type(value) is not int or not 0 <= value <= 60:
            raise ValueError('manual stale resample budget must be an integer from 0 to 60')
        return value
    wallet_deposit_intent_ttl_seconds: int = 1200
    wallet_funding_baseline_at: datetime | None = None
    wallet_funding_baseline_height: int | None = None
    wallet_alert_recipient: SecretStr | None = None

    @field_validator('wallet_manual_max_per', 'wallet_manual_user_24h', 'wallet_manual_global_24h', mode='before')
    @classmethod
    def validate_manual_limits(cls, value):
        if value is not None and (not isinstance(value, str)
                or re.fullmatch(r'(0|[1-9][0-9]{0,23})\.[0-9]{6}', value) is None
                or Decimal(value) < Decimal('10')):
            raise ValueError('manual payout limits require exact six-place decimal strings >= 10')
        return value

    @model_validator(mode='after')
    def validate_manual_runtime(self):
        independent = any(value is True for value in (self.wallet_deposits_enabled,
            self.wallet_payout_requests_enabled, self.wallet_payout_execution_enabled))
        if self.wallet_reserve_policy == 'manual_liquidity' and self.wallet_real_mode != 'manual_tron':
            raise ValueError('manual liquidity policy requires explicit manual TRON mode')
        if self.wallet_handover_preparation_mode and (independent or self.wallet_conversions_enabled):
            raise ValueError('handover preparation requires every money capability disabled')
        if self.wallet_handover_preparation_mode and (self.wallet_real_mode != 'manual_tron' or self.wallet_real_funds_enabled):
            raise ValueError('handover preparation requires manual TRON with funds disabled')
        if self.wallet_real_mode == 'disabled':
            if self.wallet_real_funds_enabled or independent:
                raise ValueError('real funds require explicit manual TRON mode')
            return self
        required = (self.wallet_totp_encryption_key, self.wallet_binding_domain, self.wallet_official_address,
            self.wallet_official_config_version, self.wallet_manual_owner_admin_id, self.wallet_manual_policy_version,
            self.wallet_manual_max_per, self.wallet_manual_user_24h, self.wallet_manual_global_24h,
            self.wallet_funding_baseline_at)
        if any(value is None or isinstance(value, str) and not value.strip() for value in required):
            raise ValueError('manual TRON mode requires explicit identity, policy and activation baseline settings')
        from app.integrations.tron.message_signature import canonical_address
        try:
            canonical_address(self.wallet_official_address.get_secret_value())
        except (ValueError, TypeError):
            raise ValueError('manual TRON official address invalid') from None
        if self.wallet_funding_baseline_at.tzinfo is None or self.wallet_funding_baseline_at.utcoffset() is None:
            raise ValueError('manual TRON baseline must include timezone')
        if self.wallet_funding_baseline_height is None or self.wallet_funding_baseline_height < 0:
            raise ValueError('manual TRON baseline height required')
        if not 1 <= self.wallet_manual_quote_ttl_seconds <= 3600 or not 1 <= self.wallet_deposit_intent_ttl_seconds <= 86400:
            raise ValueError('manual TRON quote/intent expiry out of bounds')
        return self

    @field_validator("wallet_confirmation_threshold")
    @classmethod
    def validate_wallet_confirmation_threshold(cls, value: int) -> int:
        if value < 20:
            raise ValueError("wallet confirmation threshold must be at least 20")
        return value
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



