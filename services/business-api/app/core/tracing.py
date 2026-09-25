"""Audit tracing and separate, bounded performance request observations."""

import re
from collections import OrderedDict, deque
from math import ceil
from threading import Lock
from time import perf_counter
from uuid import uuid4

from fastapi import Request


_TRACE_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
_PERFORMANCE_ID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
)
_ALLOWED_METHODS = frozenset({"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"})
_UNMATCHED_ROUTE = "<unmatched>"


class RequestLatencyMetrics:
    """Process-local aggregate and bounded operation-correlated request timing."""

    def __init__(self, *, sample_capacity: int = 512, series_capacity: int = 256,
                 correlation_capacity: int = 256) -> None:
        if sample_capacity < 1 or series_capacity < 1 or correlation_capacity < 1:
            raise ValueError("metric capacities must be positive")
        self._sample_capacity = sample_capacity
        self._series_capacity = series_capacity
        self._samples: OrderedDict[tuple[str, str, int], deque[float]] = OrderedDict()
        self._recent_operation_requests: deque[tuple[str, str, int, float]] = deque(
            maxlen=correlation_capacity
        )
        self._lock = Lock()

    def record(self, method: str, route_template: str, status_code: int,
               duration_ms: float, *, performance_id: str | None = None) -> None:
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
                    safe_performance_id, route_template, status_code, safe_duration_ms,
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
                }
                for operation_id, route_template, status_code, duration_ms in recent
            ],
        }


def _validated_performance_id(value: str | None) -> str | None:
    if value is None or _PERFORMANCE_ID_PATTERN.fullmatch(value) is None:
        return None
    return value.lower()


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) and path.startswith("/") else _UNMATCHED_ROUTE


def install_trace_middleware(app) -> None:
    metrics = RequestLatencyMetrics()
    app.state.request_latency_metrics = metrics

    @app.middleware("http")
    async def trace_middleware(request: Request, call_next):
        candidate = request.headers.get("X-Trace-Id", "")
        trace_id = candidate if _TRACE_ID_PATTERN.fullmatch(candidate) else uuid4().hex
        request.state.trace_id = trace_id
        performance_id = request.headers.get("X-ChatFlow-Performance-Id")
        # An explicitly reused audit trace ID must not become a performance
        # correlation key. Never write this header into request.state.
        if performance_id is not None and performance_id.lower() == trace_id.lower():
            performance_id = None
        started = perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            response.headers["X-Trace-Id"] = trace_id
            return response
        finally:
            metrics.record(
                request.method,
                _route_template(request),
                status_code,
                (perf_counter() - started) * 1000.0,
                performance_id=performance_id,
            )
