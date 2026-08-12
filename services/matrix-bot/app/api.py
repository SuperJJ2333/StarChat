from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Header, HTTPException, status

from app.idempotency import IdempotencyStore
from app.matrix_client import MatrixBotClient
from app.models import MatrixPublishRequest, MatrixPublishResponse
from app.room_policy import RoomTargetNotAllowed
from app.router import RoomRouter
from app.settings import Settings


def create_api_router(
    settings: Settings,
    room_router: RoomRouter,
    bot_client: MatrixBotClient,
    idempotency_store: IdempotencyStore,
) -> APIRouter:
    router = APIRouter()

    async def require_api_key(
        x_matrix_webhook_key: Annotated[str | None, Header(alias="X-Matrix-Webhook-Key")] = None,
    ) -> None:
        if x_matrix_webhook_key != settings.matrix_internal_api_key:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid API key.")

    @router.get("/health")
    async def health() -> dict[str, object]:
        return {
            "ok": True,
            "service": settings.app_name,
            "matrix_ready": bot_client.is_ready,
        }

    @router.post(
        "/internal/matrix/publish",
        response_model=MatrixPublishResponse,
        dependencies=[Depends(require_api_key)],
    )
    async def publish_message(request: MatrixPublishRequest) -> MatrixPublishResponse:
        if request.idempotency_key:
            cached = idempotency_store.get(request.idempotency_key)
            if cached is not None:
                response = MatrixPublishResponse.model_validate(cached)
                response.deduplicated = True
                response.message = "deduplicated"
                return response

        target = room_router.resolve(request)
        if target is None:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="No room target resolved. Provide room_id, room_alias, route_key, or a default route.",
            )

        try:
            event_id, room_id = await bot_client.send_message(target.value, request.message)
        except RoomTargetNotAllowed as exc:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="MATRIX_ROOM_NOT_ALLOWED",
            ) from exc
        response = MatrixPublishResponse(
            room_target=target.value,
            room_id=room_id,
            event_id=event_id,
        )

        if request.idempotency_key:
            idempotency_store.put(request.idempotency_key, response.model_dump())

        return response

    return router
