from uuid import uuid4

from fastapi import FastAPI, Request
from httpx import ASGITransport, AsyncClient
import pytest

from app.core.tracing import RequestLatencyMetrics, install_trace_middleware


@pytest.mark.asyncio
async def test_request_latency_uses_route_template_without_request_values():
    app = FastAPI()
    install_trace_middleware(app)

    @app.get("/users/{user_id}")
    async def user(user_id: str):
        return {"ok": True}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/users/private-user?token=private-token")
        missing = await client.get("/private-missing?token=private-token")

    assert response.status_code == 200
    assert missing.status_code == 404
    assert hasattr(app.state, "request_latency_metrics")
    snapshot = app.state.request_latency_metrics.snapshot()
    assert any(
        item["method"] == "GET"
        and item["route_template"] == "/users/{user_id}"
        and item["status_code"] == 200
        and item["count"] == 1
        for item in snapshot["requests"]
    )
    assert any(item["route_template"] == "<unmatched>" and item["status_code"] == 404
               for item in snapshot["requests"])
    assert "private-user" not in str(snapshot)
    assert "private-token" not in str(snapshot)
    assert "private-missing" not in str(snapshot)


@pytest.mark.asyncio
async def test_request_latency_window_is_bounded_and_has_tail_percentiles():
    app = FastAPI()
    install_trace_middleware(app)
    assert hasattr(app.state, "request_latency_metrics")
    metrics = app.state.request_latency_metrics
    for duration_ms in range(1, 601):
        metrics.record("GET", "/test/{id}", 200, float(duration_ms))
    sample = next(item for item in metrics.snapshot()["requests"]
                  if item["route_template"] == "/test/{id}")
    assert sample["count"] == 512
    assert sample["p50_ms"] == 344
    assert sample["p95_ms"] == 575
    assert sample["p99_ms"] == 595
    assert sample["max_ms"] == 600


@pytest.mark.asyncio
async def test_request_latency_records_server_error_without_private_path():
    app = FastAPI()
    install_trace_middleware(app)

    @app.get("/fail/{user_id}")
    async def failed(user_id: str):
        raise RuntimeError("private exception text")

    async with AsyncClient(
        transport=ASGITransport(app=app, raise_app_exceptions=False),
        base_url="http://test",
    ) as client:
        response = await client.get("/fail/private-user")

    assert response.status_code == 500
    snapshot = app.state.request_latency_metrics.snapshot()
    assert any(item["route_template"] == "/fail/{user_id}" and item["status_code"] == 500
               for item in snapshot["requests"])
    assert "private-user" not in str(snapshot)
    assert "private exception text" not in str(snapshot)


def test_request_latency_series_count_is_bounded():
    app = FastAPI()
    install_trace_middleware(app)
    metrics = app.state.request_latency_metrics
    for index in range(300):
        metrics.record("GET", f"/route/{index}", 200, 1.0)
    assert len(metrics.snapshot()["requests"]) == 256


@pytest.mark.asyncio
async def test_performance_header_correlates_without_touching_audit_trace_id():
    app = FastAPI()
    install_trace_middleware(app)
    operation_id = str(uuid4())

    @app.get("/users/{user_id}")
    async def user(request: Request, user_id: str):
        return {"audit_trace_id": request.state.trace_id}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/users/private-user?token=private-token",
            headers={
                "X-Trace-Id": "audit-trace-id",
                "X-ChatFlow-Performance-Id": operation_id,
            },
        )
    assert response.status_code == 200
    assert response.headers["X-Trace-Id"] == "audit-trace-id"
    assert response.json()["audit_trace_id"] == "audit-trace-id"
    snapshot = app.state.request_latency_metrics.snapshot()
    assert len(snapshot["recent_operation_requests"]) == 1
    recent = snapshot["recent_operation_requests"][0]
    assert set(recent) == {"operation_id", "route_template", "status_code", "duration_ms"}
    assert recent["operation_id"] == operation_id
    assert recent["route_template"] == "/users/{user_id}"
    assert recent["status_code"] == 200
    assert recent["duration_ms"] >= 0
    for private in ("private-user", "private-token", "audit-trace-id"):
        assert private not in str(snapshot)


@pytest.mark.asyncio
async def test_missing_invalid_or_audit_reused_performance_ids_are_ignored():
    app = FastAPI()
    install_trace_middleware(app)

    @app.get("/safe")
    async def safe():
        return {"ok": True}

    reused = str(uuid4())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        await client.get("/safe")
        for candidate in (
            "private-id",
            "00000000-0000-1000-8000-000000000000",
            "00000000-0000-4000-0000-000000000000",
            "/safe?token=private-token",
        ):
            await client.get("/safe", headers={"X-ChatFlow-Performance-Id": candidate})
        await client.get("/safe", headers={
            "X-Trace-Id": reused,
            "X-ChatFlow-Performance-Id": reused,
        })
    assert app.state.request_latency_metrics.snapshot()["recent_operation_requests"] == []


def test_recent_operation_request_buffer_is_bounded_and_rejects_raw_ids():
    metrics = RequestLatencyMetrics(correlation_capacity=3)
    ids = [str(uuid4()) for _ in range(5)]
    metrics.record("GET", "/safe", 200, 1.0, performance_id="private-id")
    for operation_id in ids:
        metrics.record("GET", "/safe", 200, 1.0, performance_id=operation_id)
    recent = metrics.snapshot()["recent_operation_requests"]
    assert [item["operation_id"] for item in recent] == ids[-3:]
    assert all(item["route_template"] == "/safe" for item in recent)
    assert "private-id" not in str(recent)
