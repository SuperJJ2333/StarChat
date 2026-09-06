from typing import Annotated

from fastapi import APIRouter, Depends, Header

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.settings.service import (
    APP_APK_URL_KEY,
    APP_LATEST_BUILD_KEY,
    APP_LATEST_VERSION_KEY,
    APP_MIN_SUPPORTED_BUILD_KEY,
    APP_UPDATE_NOTES_KEY,
    APP_UPDATE_SETTING_KEYS,
    SettingService,
)


def create_app_update_router(settings: Settings, session_factory) -> APIRouter:
    router = APIRouter(prefix="/app-updates", tags=["app-updates"])
    app_settings = SettingService(session_factory)
    tokens = TokenService(
        session_factory,
        jwt_secret=settings.jwt_secret or "development-jwt-secret-at-least-thirty-two-bytes",
        jwt_issuer=settings.jwt_issuer,
        require_session_claims=settings.environment != "test",
    )

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith("Bearer "):
            raise AppError(code="AUTH_REQUIRED", message="需要登录", status_code=401)
        return str(tokens.decode_access_token(authorization[7:])["sub"])

    @router.get("/latest")
    def latest(user_id: str = Depends(actor)):
        del user_id  # Any authenticated client may learn the latest release.
        values = app_settings.get_many(APP_UPDATE_SETTING_KEYS)
        latest_build = values[APP_LATEST_BUILD_KEY]
        if latest_build is None:
            return {
                "configured": False,
                "latest_version": None,
                "latest_build": None,
                "min_supported_build": None,
                "notes": None,
                "apk_url": None,
            }
        return {
            "configured": True,
            "latest_version": values[APP_LATEST_VERSION_KEY],
            "latest_build": int(latest_build),
            "min_supported_build": int(
                values[APP_MIN_SUPPORTED_BUILD_KEY] or "0"
            ),
            "notes": values[APP_UPDATE_NOTES_KEY],
            "apk_url": values[APP_APK_URL_KEY],
        }

    return router
