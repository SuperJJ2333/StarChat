from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header

from app.core.config import Settings
from app.core.errors import AppError
from app.modules.identity.tokens import TokenService
from app.modules.settings.service import (
    APP_IOS_UPDATE_SETTING_KEYS,
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
    def latest(
        platform: Literal["android", "ios"] = "android",
        user_id: str = Depends(actor),
    ):
        del user_id  # Any authenticated client may learn the latest release.
        keys = APP_IOS_UPDATE_SETTING_KEYS if platform == "ios" else APP_UPDATE_SETTING_KEYS
        version_key, build_key, minimum_key, notes_key, url_key = keys
        values = app_settings.get_many(keys)
        # The marker lets iOS clients reject legacy servers that ignore platform.
        platform_fields = {"platform": "ios"} if platform == "ios" else {}
        latest_build = values[build_key]
        if latest_build is None:
            return {
                **platform_fields,
                "configured": False,
                "latest_version": None,
                "latest_build": None,
                "min_supported_build": None,
                "notes": None,
                "apk_url": None,
            }
        return {
            **platform_fields,
            "configured": True,
            "latest_version": values[version_key],
            "latest_build": int(latest_build),
            "min_supported_build": int(
                values[minimum_key] or "0"
            ),
            "notes": values[notes_key],
            "apk_url": values[url_key],
        }

    return router
