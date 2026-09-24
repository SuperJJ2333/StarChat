"""The existing media maintenance gate shared by read-only diagnostics."""

from typing import Annotated

from fastapi import Header

from app.core.config import Settings
from app.core.errors import AppError


def media_maintenance_dependency(
    settings: Settings, *, require_token_in_staging: bool = False,
):
    def require_maintenance(
        token: Annotated[str | None, Header(alias="X-Media-Maintenance-Token")] = None,
    ) -> None:
        expected = settings.media_maintenance_token
        if expected:
            if token != expected:
                raise AppError(
                    code="MEDIA_MAINTENANCE_FORBIDDEN",
                    message="维护接口不可用",
                    status_code=403,
                )
            return
        if settings.environment == "production" or (
            require_token_in_staging and settings.environment == "staging"
        ):
            raise AppError(
                code="MEDIA_MAINTENANCE_UNAVAILABLE",
                message="维护接口未配置",
                status_code=503,
            )

    return require_maintenance
