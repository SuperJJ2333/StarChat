from fastapi import FastAPI

from app.api.health import create_health_router
from app.core.config import Settings


def create_app(settings: Settings, session_factory=None) -> FastAPI:
    app = FastAPI(title=settings.app_name, version="0.1.0")
    app.include_router(
        create_health_router(settings, session_factory=session_factory),
        prefix="/api/v1",
    )
    return app
