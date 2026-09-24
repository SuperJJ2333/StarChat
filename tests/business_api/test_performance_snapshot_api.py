"""Protected, identifier-free readout of existing in-process metrics."""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from uuid import uuid4

from app.core.config import Settings
from app.core.database import create_engine
from app.core.rate_limits import NoopRateLimiter
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app


@pytest.fixture
def snapshot_app(tmp_path):
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret="test-snapshot-secret-at-least-32-bytes",
        avatar_storage_root=str(tmp_path / "private-media"),
    )
    session_calls = []

    def forbidden_session():
        session_calls.append(True)
        raise AssertionError("performance snapshot must not open a DB session")

    app = create_app(
        settings,
        session_factory=forbidden_session,
        rate_limiter=NoopRateLimiter(),
        avatar_storage=LocalPrivateObjectStorage(
            root=settings.avatar_storage_root,
            signing_secret="test-snapshot-signing-secret-at-least-32-bytes",
            public_base_url="http://test.local",
        ),
    )
    return app, settings, session_calls


def test_performance_snapshot_reuses_maintenance_gate_and_fails_closed(snapshot_app):
    app, settings, session_calls = snapshot_app
    settings.media_maintenance_token = "private-maintenance-token"
    with TestClient(app) as client:
        missing = client.get("/api/v1/diagnostics/performance")
        wrong = client.get(
            "/api/v1/diagnostics/performance",
            headers={"X-Media-Maintenance-Token": "wrong"},
        )
        allowed = client.get(
            "/api/v1/diagnostics/performance",
            headers={"X-Media-Maintenance-Token": "private-maintenance-token"},
        )
        assert missing.status_code == wrong.status_code == 403
        assert allowed.status_code == 200
        assert allowed.headers["Cache-Control"] == "no-store"
        assert "private-maintenance-token" not in allowed.text

        settings.media_maintenance_token = None
        settings.environment = "production"
        unavailable = client.get("/api/v1/diagnostics/performance")
        assert unavailable.status_code == 503
    assert session_calls == []


def test_performance_snapshot_preserves_percentiles_and_private_boundaries(snapshot_app):
    app, settings, session_calls = snapshot_app
    settings.media_maintenance_token = "private-maintenance-token"

    async def private_route(user_id: str):
        return {"ok": True}

    app.add_api_route("/users/{user_id}", private_route, methods=["GET"])
    for duration_ms in range(1, 101):
        app.state.request_latency_metrics.record(
            "GET", "/users/{user_id}", 200, float(duration_ms)
        )
    app.state.request_latency_metrics.record("GET", "/users/private-user", 200, 9000)
    engine = create_engine(settings)
    try:
        with engine.connect() as connection:
            connection.execute(text("SELECT :private_value"), {
                "private_value": "private-sql-parameter",
            })
        metrics = engine._chatflow_database_metrics
        for duration_ms in range(1, 101):
            metrics.record_query(float(duration_ms))
        before = metrics.snapshot(engine.pool)
        app.state.engine = engine

        with TestClient(app) as client:
            response = client.get(
                "/api/v1/diagnostics/performance?room_id=private-room-id",
                headers={"X-Media-Maintenance-Token": "private-maintenance-token"},
            )
        assert response.status_code == 200
        payload = response.json()
        request = next(item for item in payload["requests"]
                       if item["route_template"] == "/users/{user_id}")
        assert {key: request[key] for key in
                ("count", "p50_ms", "p95_ms", "p99_ms", "max_ms")} == {
                    "count": 100, "p50_ms": 50, "p95_ms": 95,
                    "p99_ms": 99, "max_ms": 100,
                }
        database = payload["database"]
        assert database["supported"] is True
        assert database["query_latency"] == before["query_latency"]
        assert database["slow_query_count"] == before["slow_query_count"]
        assert database["connection_wait_ms"] is None
        assert "pool" in database
        assert "timings" in payload["media"]
        assert metrics.snapshot(engine.pool)["query_latency"]["count"] == before["query_latency"]["count"]
        for private in (
            "private-maintenance-token", "private-sql-parameter",
            "private-room-id", "private-user", "SELECT", "192.0.2.1",
        ):
            assert private not in response.text
        assert session_calls == []
    finally:
        engine.dispose()


def test_injected_session_factory_exposes_unsupported_db_without_connecting(snapshot_app):
    app, _, session_calls = snapshot_app
    assert not hasattr(app.state, "engine")
    with TestClient(app) as client:
        response = client.get("/api/v1/diagnostics/performance")
    assert response.status_code == 200
    assert response.json()["database"] == {
        "supported": False,
        "query_latency": None,
        "slow_query_count": None,
        "pool": None,
        "connection_wait_ms": None,
    }
    assert session_calls == []


def test_staging_without_maintenance_token_fails_closed(snapshot_app):
    app, settings, session_calls = snapshot_app
    settings.environment = "staging"
    settings.media_maintenance_token = None
    with TestClient(app) as client:
        response = client.get("/api/v1/diagnostics/performance")
        existing_media = client.get("/api/v1/media/platform/metrics")
    assert response.status_code == 503
    assert existing_media.status_code == 200
    assert session_calls == []


def test_protected_snapshot_exposes_only_safe_recent_operation_requests(snapshot_app):
    app, settings, session_calls = snapshot_app
    settings.media_maintenance_token = "private-maintenance-token"
    operation_id = str(uuid4())

    async def private_route(user_id: str):
        return {"ok": True}

    app.add_api_route("/users/{user_id}", private_route, methods=["GET"])
    with TestClient(app) as client:
        request = client.get(
            "/users/private-user?token=private-query",
            headers={"X-ChatFlow-Performance-Id": operation_id},
        )
        assert request.status_code == 200
        app.state.request_latency_metrics.record(
            "GET", "/users/private-user", 200, 1.0,
            performance_id=str(uuid4()),
        )
        denied = client.get("/api/v1/diagnostics/performance")
        assert denied.status_code == 403
        response = client.get(
            "/api/v1/diagnostics/performance",
            headers={"X-Media-Maintenance-Token": "private-maintenance-token"},
        )
    assert response.status_code == 200
    recent = response.json()["recent_operation_requests"]
    assert len(recent) == 1
    assert recent[0]["operation_id"] == operation_id
    assert recent[0]["route_template"] == "/users/{user_id}"
    assert recent[0]["status_code"] == 200
    assert recent[0]["duration_ms"] >= 0
    for private in ("private-user", "private-query", "private-maintenance-token"):
        assert private not in response.text
    assert session_calls == []
