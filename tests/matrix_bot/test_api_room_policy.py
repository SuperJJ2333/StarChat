from pathlib import Path

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.api import create_api_router
from app.idempotency import IdempotencyStore
from app.room_policy import RoomTargetNotAllowed
from app.router import RoomRouter
from app.settings import Settings


class RejectingBotClient:
    is_ready = True

    async def send_message(self, room_target: str, message: object) -> tuple[str, str]:
        raise RoomTargetNotAllowed(room_target)


@pytest.mark.asyncio
async def test_publish_maps_room_policy_failure_to_stable_403(tmp_path: Path) -> None:
    settings = Settings(
        MATRIX_HOMESERVER_URL="https://matrix.example.test/",
        MATRIX_BOT_USER_ID="@notification:example.test",
        MATRIX_BOT_PASSWORD="test-password",
        MATRIX_INTERNAL_API_KEY="test-key",
    )
    store = IdempotencyStore(str(tmp_path / "idempotency.sqlite3"), ttl_seconds=60)
    app = FastAPI()
    app.include_router(
        create_api_router(
            settings,
            RoomRouter({}, None),
            RejectingBotClient(),  # type: ignore[arg-type]
            store,
        )
    )

    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://testserver") as client:
        response = await client.post(
            "/internal/matrix/publish",
            headers={"X-Matrix-Webhook-Key": "test-key"},
            json={
                "room_id": "!private:example.test",
                "message": {"body": "notification"},
            },
        )

    store.close()
    assert response.status_code == 403
    assert response.json() == {"detail": "MATRIX_ROOM_NOT_ALLOWED"}
