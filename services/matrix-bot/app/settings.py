from __future__ import annotations

import json
from functools import cached_property
from typing import Any

from pydantic import Field, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = Field(default="六合通 Matrix Bot", alias="APP_NAME")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")
    service_port: int = Field(default=8081, alias="SERVICE_PORT")

    matrix_homeserver_url: str = Field(..., alias="MATRIX_HOMESERVER_URL")
    matrix_bot_user_id: str = Field(..., alias="MATRIX_BOT_USER_ID")
    matrix_bot_password: str | None = Field(default=None, alias="MATRIX_BOT_PASSWORD")
    matrix_bot_access_token: str | None = Field(default=None, alias="MATRIX_BOT_ACCESS_TOKEN")
    matrix_bot_device_id: str | None = Field(default=None, alias="MATRIX_BOT_DEVICE_ID")
    matrix_bot_store_path: str = Field(default="/data/bot/store", alias="MATRIX_BOT_STORE_PATH")

    matrix_internal_api_key: str = Field(..., alias="MATRIX_INTERNAL_API_KEY")
    matrix_default_room_id: str | None = Field(default=None, alias="MATRIX_DEFAULT_ROOM_ID")
    matrix_room_routing_json: str = Field(default="{}", alias="MATRIX_ROOM_ROUTING_JSON")
    matrix_allowed_room_targets_json: str = Field(default="[]", alias="MATRIX_ALLOWED_ROOM_TARGETS_JSON")
    matrix_auto_reply_rules_json: str = Field(default="[]", alias="MATRIX_AUTO_REPLY_RULES_JSON")
    matrix_admin_users_json: str = Field(default="[]", alias="MATRIX_ADMIN_USERS_JSON")
    matrix_command_prefix: str = Field(default="!", alias="MATRIX_COMMAND_PREFIX")

    matrix_sync_timeout_ms: int = Field(default=30000, alias="MATRIX_SYNC_TIMEOUT_MS")
    matrix_sync_full_state: bool = Field(default=True, alias="MATRIX_SYNC_FULL_STATE")
    matrix_message_dedup_ttl_seconds: int = Field(default=3600, alias="MATRIX_MESSAGE_DEDUP_TTL_SECONDS")
    matrix_idempotency_db_path: str = Field(default="/data/bot/idempotency.sqlite3", alias="MATRIX_IDEMPOTENCY_DB_PATH")
    matrix_allow_unverified_devices: bool = Field(default=True, alias="MATRIX_ALLOW_UNVERIFIED_DEVICES")

    @field_validator("matrix_homeserver_url")
    @classmethod
    def normalize_matrix_homeserver_url(cls, value: str) -> str:
        return value.rstrip("/")

    @model_validator(mode="after")
    def validate_credentials(self) -> "Settings":
        if not self.matrix_bot_access_token and not self.matrix_bot_password:
            raise ValueError("Set MATRIX_BOT_PASSWORD or MATRIX_BOT_ACCESS_TOKEN.")

        if self.matrix_bot_access_token and not self.matrix_bot_device_id:
            raise ValueError("MATRIX_BOT_DEVICE_ID is required when MATRIX_BOT_ACCESS_TOKEN is set.")

        return self

    @cached_property
    def room_routing(self) -> dict[str, str]:
        data = self._load_json(self.matrix_room_routing_json, expected_type=dict, variable_name="MATRIX_ROOM_ROUTING_JSON")
        return {str(key): str(value) for key, value in data.items() if value}

    @cached_property
    def auto_reply_rules(self) -> list[dict[str, Any]]:
        data = self._load_json(self.matrix_auto_reply_rules_json, expected_type=list, variable_name="MATRIX_AUTO_REPLY_RULES_JSON")
        return [dict(item) for item in data]

    @cached_property
    def allowed_room_targets(self) -> set[str]:
        data = self._load_json(
            self.matrix_allowed_room_targets_json,
            expected_type=list,
            variable_name="MATRIX_ALLOWED_ROOM_TARGETS_JSON",
        )
        return {str(item) for item in data if item}

    @cached_property
    def admin_users(self) -> set[str]:
        data = self._load_json(self.matrix_admin_users_json, expected_type=list, variable_name="MATRIX_ADMIN_USERS_JSON")
        return {str(item) for item in data}

    @staticmethod
    def _load_json(raw: str, *, expected_type: type, variable_name: str) -> Any:
        try:
            data = json.loads(raw or "")
        except json.JSONDecodeError as exc:
            raise ValueError(f"{variable_name} must contain valid JSON.") from exc

        if not isinstance(data, expected_type):
            raise ValueError(f"{variable_name} must decode to {expected_type.__name__}.")

        return data
