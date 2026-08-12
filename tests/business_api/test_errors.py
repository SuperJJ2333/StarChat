from typing import Annotated

from fastapi import Query
from httpx import ASGITransport, AsyncClient
import pytest

from app.core.config import Settings
from app.core.errors import AppError
from app.main import create_app


def _app():
    settings = Settings(
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
    )
    app = create_app(settings)

    @app.get("/test/error")
    async def error_route():
        raise AppError(code="ACCOUNT_LOCKED", message="账号已锁定", status_code=423)

    @app.get("/test/validation")
    async def validation_route(amount: Annotated[int, Query(gt=0)]):
        return {"amount": amount}

    return app


@pytest.mark.asyncio
async def test_app_error_has_stable_shape_and_trace_id() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=_app()), base_url="http://test"
    ) as client:
        response = await client.get(
            "/test/error", headers={"X-Trace-Id": "trace-123"}
        )

    assert response.status_code == 423
    assert response.headers["X-Trace-Id"] == "trace-123"
    assert response.json() == {
        "error": {
            "code": "ACCOUNT_LOCKED",
            "message": "账号已锁定",
            "trace_id": "trace-123",
            "fields": [],
        }
    }


@pytest.mark.asyncio
async def test_validation_error_is_normalized() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=_app()), base_url="http://test"
    ) as client:
        response = await client.get("/test/validation", params={"amount": "0"})

    assert response.status_code == 422
    payload = response.json()
    assert payload["error"]["code"] == "VALIDATION_ERROR"
    assert payload["error"]["trace_id"]
    assert payload["error"]["fields"][0]["loc"][-1] == "amount"
