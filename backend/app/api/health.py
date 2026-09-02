from fastapi import APIRouter
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import text

from app.core.config import Settings


class LiveHealthResponse(BaseModel):
    ok: bool
    service: str


class ReadyHealthResponse(LiveHealthResponse):
    database: str


def create_health_router(settings: Settings, session_factory=None) -> APIRouter:
    router = APIRouter(tags=["health"])

    @router.get("/health/live", response_model=LiveHealthResponse)
    async def live() -> LiveHealthResponse:
        return LiveHealthResponse(ok=True, service=settings.app_name)

    @router.get("/health/ready", response_model=ReadyHealthResponse)
    async def ready():
        try:
            with session_factory() as session:
                session.execute(text("SELECT 1"))
        except Exception:
            return JSONResponse(
                status_code=503,
                content={
                    "ok": False,
                    "service": settings.app_name,
                    "database": "unavailable",
                },
            )
        return ReadyHealthResponse(ok=True, service=settings.app_name, database="ready")

    return router
