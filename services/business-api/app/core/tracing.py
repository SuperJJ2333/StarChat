"""Audit tracing and separate, bounded performance request observations."""

import asyncio
import re
from collections import OrderedDict, deque
from contextvars import ContextVar
from dataclasses import dataclass
from inspect import iscoroutinefunction
from math import isfinite
from math import ceil
from threading import Lock
from time import perf_counter
from uuid import uuid4

from fastapi import APIRouter, Request
from starlette.datastructures import MutableHeaders


_TRACE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_PERFORMANCE_ID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
_ALLOWED_METHODS = frozenset({"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"})
_UNMATCHED_ROUTE = "<unmatched>"
_request_database_scope: ContextVar['_RequestDatabaseScope | None'] = ContextVar(
    'chatflow_request_database_scope', default=None,
)


@dataclass(frozen=True)
class RequestDatabaseMeasurements:
    query_count: int
    query_error_count: int
    query_total_ms: float
    query_max_ms: float
    slow_query_count: int
    attribution_complete: bool

    def to_json(self) -> dict:
        return {'query_count': self.query_count, 'query_error_count': self.query_error_count,
                'query_total_ms': self.query_total_ms, 'query_max_ms': self.query_max_ms,
                'slow_query_count': self.slow_query_count,
                'attribution_complete': self.attribution_complete, 'connection_wait_ms': None}


def _current_task():
    try:
        return asyncio.current_task()
    except RuntimeError:
        # FastAPI sync endpoints execute in an AnyIO worker with copied context.
        return None


class _RequestDatabaseScope:
    """Constant-space query facts for one live response, never SQL or parameters."""

    def __init__(self, engine, request_scope) -> None:
        self.engine = engine
        self._request_scope = request_scope
        self._owner = _current_task()
        self._active = True
        self._lock = Lock()
        self._count = self._errors = self._slow = 0
        self._total_ms = self._max_ms = 0.0
        self._attribution_complete = True

    def permits_current_execution(self) -> bool:
        task = _current_task()
        if not self._active:
            return False
        if task is self._owner:
            return True
        if task is not None:
            return False
        endpoint = self._request_scope.get('endpoint')
        # Context copied into a worker cannot reveal which async task dispatched
        # it through a public API. Only native sync endpoints are attributable;
        # async-to-worker execution is explicitly incomplete, never guessed.
        if endpoint is not None and not iscoroutinefunction(endpoint):
            return True
        with self._lock:
            self._attribution_complete = False
        return False

    def record(self, duration_ms: float, *, failed: bool, slow: bool) -> None:
        if not isfinite(duration_ms) or not self.permits_current_execution():
            return
        duration_ms = max(0.0, duration_ms)
        with self._lock:
            if not self._active:
                return
            self._count += 1
            self._errors += int(failed)
            self._slow += int(slow)
            self._total_ms += duration_ms
            self._max_ms = max(self._max_ms, duration_ms)

    def close(self) -> RequestDatabaseMeasurements:
        with self._lock:
            self._active = False
            return RequestDatabaseMeasurements(
                self._count, self._errors, self._total_ms, self._max_ms,
                self._slow, self._attribution_complete,
            )


def capture_request_database_scope(engine):
    """Capture only the actual engine and live request scope at query start."""
    scope = _request_database_scope.get()
    return scope if (scope is not None and scope.engine is engine
                     and scope.permits_current_execution()) else None


class RequestLatencyMetrics:
    """Process-local aggregate and bounded operation-correlated request timing."""

    def __init__(self, *, sample_capacity: int = 512, series_capacity: int = 256,
                 correlation_capacity: int = 256) -> None:
        if sample_capacity < 1 or series_capacity < 1 or correlation_capacity < 1:
            raise ValueError("metric capacities must be positive")
        self._sample_capacity = sample_capacity
        self._series_capacity = series_capacity
        self._samples: OrderedDict[tuple[str, str, int], deque[float]] = OrderedDict()
        self._recent_operation_requests: deque[tuple] = deque(
            maxlen=correlation_capacity
        )
        self._lock = Lock()

    def record(self, method: str, route_template: str, status_code: int,
               duration_ms: float, *, performance_id: str | None = None,
               database: RequestDatabaseMeasurements | None = None) -> None:
        """O(1) bounded append; no formatting, sorting, disk, or network I/O."""
        safe_method = method if method in _ALLOWED_METHODS else "OTHER"
        safe_performance_id = _validated_performance_id(performance_id)
        safe_duration_ms = max(0.0, duration_ms)
        key = (safe_method, route_template, status_code)
        with self._lock:
            samples = self._samples.get(key)
            if samples is None:
                if len(self._samples) >= self._series_capacity:
                    self._samples.popitem(last=False)
                samples = deque(maxlen=self._sample_capacity)
                self._samples[key] = samples
            else:
                self._samples.move_to_end(key)
            samples.append(safe_duration_ms)
            if safe_performance_id is not None:
                self._recent_operation_requests.append((
                    safe_performance_id, route_template, status_code, safe_duration_ms, database,
                ))

    def snapshot(self) -> dict[str, list[dict[str, str | int | float]]]:
        with self._lock:
            windows = [(key, tuple(samples)) for key, samples in self._samples.items()]
            recent = tuple(self._recent_operation_requests)
        requests = []
        for (method, route_template, status_code), values in windows:
            ordered = sorted(values)
            count = len(ordered)

            def percentile(percent: float) -> float:
                return ordered[ceil(count * percent) - 1]

            requests.append({
                "method": method,
                "route_template": route_template,
                "status_code": status_code,
                "count": count,
                "p50_ms": percentile(0.50),
                "p95_ms": percentile(0.95),
                "p99_ms": percentile(0.99),
                "max_ms": ordered[-1],
            })
        return {
            "requests": requests,
            "recent_operation_requests": [
                {
                    "operation_id": operation_id,
                    "route_template": route_template,
                    "status_code": status_code,
                    "duration_ms": duration_ms,
                    **({'database': database.to_json()} if database is not None else {}),
                }
                for operation_id, route_template, status_code, duration_ms, database in recent
            ],
        }


def _validated_performance_id(value: str | None) -> str | None:
    if value is None or _PERFORMANCE_ID_PATTERN.fullmatch(value) is None:
        return None
    return value.lower()


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    # FastAPI 0.141 keeps an included APIRoute's original local path and
    # supplies the matched effective template in framework-owned ASGI scope.
    # Read that static template in O(1), never the actual URL/path parameters.
    fastapi_scope = request.scope.get('fastapi')
    context = fastapi_scope.get('effective_route_context') if isinstance(fastapi_scope, dict) else None
    if context is not None and getattr(context, 'original_route', None) is route:
        effective_path = getattr(context, 'path', None)
        if isinstance(effective_path, str) and effective_path.startswith('/'):
            return effective_path
    path = getattr(route, "path", None)
    return path if isinstance(path, str) and path.startswith("/") else _UNMATCHED_ROUTE


def registered_route_templates(app) -> set[str]:
    """Expand static included-router prefixes, including non-OpenAPI routes.

    Older FastAPI versions expose flattened routes directly. Newer versions
    retain the original APIRouter and prefix; this snapshot-only traversal
    follows that static registration graph without building OpenAPI or
    inspecting a request URL, endpoint arguments, or SQL.
    """
    templates = set()
    pending = [(app.routes, '')]
    while pending:
        routes, prefix = pending.pop()
        for route in routes:
            original = getattr(route, 'original_router', None)
            include_context = getattr(route, 'include_context', None)
            include_prefix = getattr(include_context, 'prefix', None)
            if isinstance(original, APIRouter) and isinstance(include_prefix, str):
                pending.append((original.routes, prefix + include_prefix))
                continue
            path = getattr(route, 'path', None)
            if isinstance(path, str) and path.startswith('/'):
                templates.add(prefix + path)
    return templates


class _PerformanceRequestMiddleware:
    def __init__(self, app, *, metrics: RequestLatencyMetrics, owner_app) -> None:
        self.app, self.metrics, self.owner_app = app, metrics, owner_app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            await self.app(scope, receive, send)
            return
        request = Request(scope)
        candidate = request.headers.get("X-Trace-Id", "")
        trace_id = candidate if _TRACE_ID_PATTERN.fullmatch(candidate) else uuid4().hex
        request.state.trace_id = trace_id
        performance_id = request.headers.get("X-ChatFlow-Performance-Id")
        # An explicitly reused audit trace ID must not become a performance
        # correlation key. Never write this header into request.state.
        if performance_id is not None and performance_id.lower() == trace_id.lower():
            performance_id = None
        performance_id = _validated_performance_id(performance_id)
        engine = getattr(self.owner_app.state, 'engine', None)
        database_scope = (_RequestDatabaseScope(engine, scope)
                          if performance_id is not None and engine is not None
                          and hasattr(engine, '_chatflow_database_metrics') else None)
        token = _request_database_scope.set(database_scope)
        started = perf_counter()
        status_code = 500
        completed = None
        database = None

        async def send_response(message):
            nonlocal status_code, completed, database
            if message['type'] == 'http.response.start':
                status_code = message['status']
                MutableHeaders(scope=message)['X-Trace-Id'] = trace_id
            elif (message['type'] == 'http.response.body'
                  and not message.get('more_body', False)):
                completed = perf_counter()
                if database_scope is not None:
                    # Fence copied background contexts before Starlette runs
                    # post-response tasks, and exclude them from request latency.
                    database = database_scope.close()
            await send(message)

        try:
            await self.app(scope, receive, send_response)
        finally:
            if database_scope is not None and database is None:
                database = database_scope.close()
            _request_database_scope.reset(token)
            self.metrics.record(
                request.method,
                _route_template(request),
                status_code,
                ((completed if completed is not None else perf_counter()) - started) * 1000.0,
                performance_id=performance_id,
                database=database,
            )


def install_trace_middleware(app) -> None:
    metrics = RequestLatencyMetrics()
    app.state.request_latency_metrics = metrics
    app.add_middleware(_PerformanceRequestMiddleware, metrics=metrics, owner_app=app)
