"""Protected read-only snapshots of existing process-local performance metrics."""

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, ConfigDict

from app.api.maintenance import media_maintenance_dependency
from app.core.config import Settings
from app.modules.media.metrics import media_platform_metrics


class _SnapshotModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LatencyWindow(_SnapshotModel):
    count: int
    p50_ms: float | None
    p95_ms: float | None
    p99_ms: float | None
    max_ms: float | None


class RequestLatencyWindow(LatencyWindow):
    method: str
    route_template: str
    status_code: int


class RecentOperationRequest(_SnapshotModel):
    operation_id: str
    route_template: str
    status_code: int
    duration_ms: float


class PoolUsage(_SnapshotModel):
    size: int | None
    checked_in: int | None
    checked_out: int | None
    overflow: int | None


class DatabaseSnapshot(_SnapshotModel):
    supported: bool
    query_latency: LatencyWindow | None
    slow_query_count: int | None
    pool: PoolUsage | None
    connection_wait_ms: float | None


class MediaLatencyWindow(LatencyWindow):
    avg_ms: float


class MediaSnapshot(_SnapshotModel):
    counters: dict[str, int]
    timings: dict[str, MediaLatencyWindow]


class PerformanceSnapshot(_SnapshotModel):
    requests: list[RequestLatencyWindow]
    recent_operation_requests: list[RecentOperationRequest]
    database: DatabaseSnapshot
    media: MediaSnapshot


def create_performance_diagnostics_router(settings: Settings) -> APIRouter:
    router = APIRouter(tags=["diagnostics"])
    require_maintenance = media_maintenance_dependency(
        settings, require_token_in_staging=True,
    )

    @router.get("/diagnostics/performance", response_model=PerformanceSnapshot)
    def read_performance_snapshot(
        request: Request,
        response: Response,
        _: None = Depends(require_maintenance),
    ) -> dict:
        response.headers["Cache-Control"] = "no-store"
        # Only registered route templates may leave the process. A raw request
        # path, query string, or accidentally injected series is never exposed.
        registered = {
            route.path for route in request.app.routes
            if isinstance(getattr(route, "path", None), str)
        }
        request_metrics = request.app.state.request_latency_metrics.snapshot()
        request_series = [
            item for item in request_metrics["requests"]
            if item["route_template"] in registered
            or item["route_template"] == "<unmatched>"
        ]
        recent_operation_requests = [
            item for item in request_metrics["recent_operation_requests"]
            if item["route_template"] in registered
            or item["route_template"] == "<unmatched>"
        ]

        engine = getattr(request.app.state, "engine", None)
        metrics = getattr(engine, "_chatflow_database_metrics", None)
        if metrics is None or not hasattr(engine, "pool"):
            database = {
                "supported": False,
                "query_latency": None,
                "slow_query_count": None,
                "pool": None,
                "connection_wait_ms": None,
            }
        else:
            database = {"supported": True, **metrics.snapshot(engine.pool)}

        return {
            "requests": request_series,
            "recent_operation_requests": recent_operation_requests,
            "database": database,
            "media": media_platform_metrics.snapshot(),
        }

    return router
