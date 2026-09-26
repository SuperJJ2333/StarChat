from uuid import uuid4

import asyncio
from fastapi import BackgroundTasks
from sqlalchemy import text
from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from starlette.concurrency import run_in_threadpool

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


def _database_app(tmp_path):
    app = FastAPI()
    engine = create_engine(Settings(_env_file=None, environment='test',
        database_url=f"sqlite+pysqlite:///{tmp_path / 'request-scopes.db'}",
        redis_url='redis://unused'))
    app.state.engine = engine
    install_trace_middleware(app)
    return app, engine, create_session_factory(engine)


@pytest.mark.asyncio
async def test_request_database_queries_are_correlated_and_concurrent_scopes_isolated(tmp_path):
    app, engine, sessions = _database_app(tmp_path)
    ready = asyncio.Event()
    count = 0

    @app.get('/query/{number}')
    async def query(number: int):
        nonlocal count
        count += 1
        if count == 2:
            ready.set()
        await ready.wait()
        with sessions() as session:
            for _ in range(number):
                session.execute(text('SELECT :private_value'), {'private_value': 'PRIVATE_SQL'})
        return {'ok': True}

    ids = [str(uuid4()), str(uuid4())]
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            responses = await asyncio.gather(*[
                client.get(f'/query/{number}?token=PRIVATE_QUERY',
                           headers={'X-ChatFlow-Performance-Id': operation_id})
                for number, operation_id in zip((1, 3), ids)
            ])
        assert all(response.status_code == 200 for response in responses)
        by_id = {row['operation_id']: row
                 for row in app.state.request_latency_metrics.snapshot()['recent_operation_requests']}
        for number, operation_id in zip((1, 3), ids):
            database = by_id[operation_id]['database']
            assert database['query_count'] == number
            assert database['query_error_count'] == 0
            assert database['query_total_ms'] >= database['query_max_ms'] >= 0
            assert database['connection_wait_ms'] is None
            assert database['attribution_complete'] is True
        assert 'PRIVATE' not in str(by_id) and 'SELECT' not in str(by_id)
    finally:
        engine.dispose()


@pytest.mark.asyncio
async def test_sync_worker_queries_are_measured_but_background_queries_are_not(tmp_path):
    app, engine, sessions = _database_app(tmp_path)

    def do_query():
        with sessions() as session:
            session.execute(text('SELECT 1'))

    @app.get('/sync')
    def sync(background: BackgroundTasks):
        do_query()
        do_query()
        background.add_task(do_query)
        return {'ok': True}

    @app.get('/child')
    async def child():
        do_query()
        async def detached():
            do_query()
        await asyncio.create_task(detached())
        return {'ok': True}

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            for path in ('/sync', '/child'):
                assert (await client.get(path, headers={
                    'X-ChatFlow-Performance-Id': str(uuid4())})).status_code == 200
        recent = app.state.request_latency_metrics.snapshot()['recent_operation_requests']
        counts = {row['route_template']: row['database']['query_count'] for row in recent}
        assert counts == {'/sync': 2, '/child': 1}
        # Global DB metrics continue to include every real query.
        assert engine._chatflow_database_metrics.snapshot(engine.pool)['query_latency']['count'] == 5
    finally:
        engine.dispose()


@pytest.mark.asyncio
async def test_failed_request_and_failed_query_keep_safe_correlated_measurements(tmp_path):
    app, engine, sessions = _database_app(tmp_path)

    @app.get('/failed/{identity}')
    async def failed(identity: str):
        with sessions() as session:
            session.execute(text('SELECT * FROM PRIVATE_MISSING_TABLE'))

    try:
        async with AsyncClient(transport=ASGITransport(app=app, raise_app_exceptions=False),
                               base_url='http://test') as client:
            response = await client.get('/failed/PRIVATE_PERSON', headers={
                'X-ChatFlow-Performance-Id': str(uuid4())})
        assert response.status_code == 500
        row = app.state.request_latency_metrics.snapshot()['recent_operation_requests'][0]
        assert row['status_code'] == 500
        assert row['route_template'] == '/failed/{identity}'
        assert row['database']['query_count'] == row['database']['query_error_count'] == 1
        assert 'PRIVATE' not in str(row) and 'SELECT' not in str(row)
    finally:
        engine.dispose()


@pytest.mark.asyncio
async def test_async_to_worker_query_attribution_is_incomplete_instead_of_guessed(tmp_path):
    app, engine, sessions = _database_app(tmp_path)

    def do_query():
        with sessions() as session:
            session.execute(text('SELECT 1'))

    @app.get('/async-worker')
    async def worker():
        await run_in_threadpool(do_query)
        async def detached():
            await run_in_threadpool(do_query)
        await asyncio.create_task(detached())
        return {'ok': True}

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url='http://test') as client:
            assert (await client.get('/async-worker', headers={
                'X-ChatFlow-Performance-Id': str(uuid4())})).status_code == 200
        row = app.state.request_latency_metrics.snapshot()['recent_operation_requests'][0]
        assert row['database']['query_count'] == 0
        assert row['database']['attribution_complete'] is False
        assert engine._chatflow_database_metrics.snapshot(engine.pool)['query_latency']['count'] == 2
    finally:
        engine.dispose()
