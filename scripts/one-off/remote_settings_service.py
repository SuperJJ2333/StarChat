from datetime import datetime, timezone
from uuid import uuid4

from sqlalchemy import select

from app.modules.audit.models import AuditEvent
from app.modules.settings.models import AppSetting

RED_PACKET_MAX_TOTAL_KEY = "red_packet_max_total"

APP_LATEST_VERSION_KEY = "app_latest_version"
APP_LATEST_BUILD_KEY = "app_latest_build"
APP_MIN_SUPPORTED_BUILD_KEY = "app_min_supported_build"
APP_UPDATE_NOTES_KEY = "app_update_notes"
APP_APK_URL_KEY = "app_apk_url"

APP_UPDATE_SETTING_KEYS = (
    APP_LATEST_VERSION_KEY,
    APP_LATEST_BUILD_KEY,
    APP_MIN_SUPPORTED_BUILD_KEY,
    APP_UPDATE_NOTES_KEY,
    APP_APK_URL_KEY,
)


class SettingService:
    def __init__(self, session_factory):
        self.session_factory = session_factory

    def get(self, key: str, *, default: str | None = None) -> str | None:
        with self.session_factory() as session:
            row = session.scalar(select(AppSetting).where(AppSetting.key == key))
            return row.value if row else default

    def set(self, key: str, value: str, *, actor_id: str, trace_id: str = "settings-update") -> AppSetting:
        now = datetime.now(timezone.utc)
        with self.session_factory.begin() as session:
            row = session.scalar(select(AppSetting).where(AppSetting.key == key).with_for_update())
            previous = row.value if row else None
            if row:
                row.value = value
                row.updated_by = actor_id
                row.updated_at = now
            else:
                row = AppSetting(key=key, value=value, updated_by=actor_id, updated_at=now)
                session.add(row)
            session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type="app_setting", subject_id=key, action="settings.update", result="SUCCESS", reason_code="ADMIN_SETTING_UPDATED", trace_id=trace_id, before_data={"value": previous}, after_data={"value": value}, created_at=now))
            session.flush()
            return row
