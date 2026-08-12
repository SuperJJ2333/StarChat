from fastapi import APIRouter

from app.core.config import Settings


def create_health_router(settings: Settings, session_factory=None) -> APIRouter:
    router = APIRouter(tags=["health"])

    @router.get("/health/live")
    async def live() -> dict[str, object]:
        return {"ok": True, "service": settings.app_name}

    return router
