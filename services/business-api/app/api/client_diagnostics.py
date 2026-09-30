"""Bounded, authenticated client reliability metadata; never accept free text."""
import hashlib
import json
import secrets
import sys
from datetime import datetime
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings
from app.core.diagnostic_identity import diagnostic_ref
from app.core.errors import AppError
from app.core.rate_limits import RateLimiter
from app.core.network_request_timeline import NetworkRequestDiagnostic
from app.modules.identity.tokens import TokenService

MAX_BODY_BYTES = 16384


class DiagnosticEvent(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    operation_id: str = Field(pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    stage: Literal['sendAdmission', 'matrixSend', 'historyLoad', 'historySearch',
                   'dateMonth', 'dateLocate', 'scrollAnchor', 'framework', 'network_request',
                   'pending_write_failed', 'request_uncertain', 'result_write_failed',
                   'retry_recovered', 'terminal_invalidated', 'result_superseded',
                   'matrix_sync_soft_kick', 'matrix_sync_hard_restart',
                   'moment_prepare', 'moment_video_begin', 'moment_video_put', 'moment_video_complete',
                   'moment_poster_extract', 'moment_poster_begin', 'moment_poster_put',
                   'moment_poster_complete', 'moment_publish']
    error: Literal['slow', 'network', 'timeout', 'rejected', 'cancelled', 'incomplete', 'unknown', 'recovered',
                   'size', 'format']
    elapsed_ms: int = Field(ge=0, le=3600000)
    count: int = Field(ge=1, le=1000000)
    status: int | None = Field(default=None, ge=100, le=599)
    retry_count: int | None = Field(default=None, ge=0, le=20)
    lifecycle: Literal['foreground', 'background', 'unknown'] | None = None

    @model_validator(mode='after')
    def consistent_stage_outcome(self):
        if self.stage in ('matrix_sync_soft_kick', 'matrix_sync_hard_restart') and self.error not in (
            'slow', 'timeout', 'unknown', 'recovered'
        ):
            raise ValueError('Unsupported watchdog diagnostic outcome')
        if self.stage in (
            'moment_prepare', 'moment_video_begin', 'moment_video_put', 'moment_video_complete',
            'moment_poster_extract', 'moment_poster_begin', 'moment_poster_put',
            'moment_poster_complete', 'moment_publish',
        ) and self.error not in ('timeout', 'network', 'rejected', 'size', 'format', 'unknown'):
            raise ValueError('Unsupported Moment diagnostic outcome')
        return self


class DiagnosticFrames(BaseModel):
    """Foreground frames exceeding build or raster refresh budget, not totalSpan."""
    model_config = ConfigDict(extra='forbid', strict=True)
    frame_count: int = Field(ge=1, le=1000000)
    slow_frame_count: int = Field(ge=0, le=1000000)
    slow_build_count: int = Field(ge=0, le=1000000)
    slow_raster_count: int = Field(ge=0, le=1000000)

    @model_validator(mode='after')
    def consistent_counts(self):
        if not (max(self.slow_build_count, self.slow_raster_count)
                <= self.slow_frame_count
                <= min(self.frame_count, self.slow_build_count + self.slow_raster_count)):
            raise ValueError('Inconsistent frame counts')
        return self


_UUID_V4 = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
_UTC_TIME = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$'


class DiagnosticLoss(BaseModel):
    """Immutable evidence of bounded local diagnostic eviction, not failures."""
    model_config = ConfigDict(extra='forbid', strict=True)
    sample_id: str = Field(pattern=_UUID_V4)
    dropped_events: int = Field(ge=0, le=1000000)
    dropped_operations: int = Field(ge=0, le=1000000)
    dropped_frames: int = Field(ge=0, le=1000000)

    @model_validator(mode='after')
    def nonzero(self):
        if not (self.dropped_events or self.dropped_operations or self.dropped_frames):
            raise ValueError('Empty diagnostic loss')
        return self


class DiagnosticFrameWindow(BaseModel):
    """One foreground main-tab interval; never a route or room identity."""
    model_config = ConfigDict(extra='forbid', strict=True)
    window_id: str = Field(pattern=_UUID_V4)
    window_start: str = Field(max_length=32, pattern=_UTC_TIME)
    window_end: str = Field(max_length=32, pattern=_UTC_TIME)
    active_tab: Literal['unknown', 'messages', 'contacts', 'discover', 'me']
    budget_us: int = Field(ge=1, le=1000000)
    frame_count: int = Field(ge=1, le=1000000)
    slow_frame_count: int = Field(ge=0, le=1000000)
    slow_build_count: int = Field(ge=0, le=1000000)
    slow_raster_count: int = Field(ge=0, le=1000000)
    max_build_us: int = Field(ge=0, le=3600000000)
    max_raster_us: int = Field(ge=0, le=3600000000)

    @model_validator(mode='after')
    def consistent_window(self):
        start = datetime.fromisoformat(self.window_start.replace('Z', '+00:00'))
        end = datetime.fromisoformat(self.window_end.replace('Z', '+00:00'))
        if start > end:
            raise ValueError('Unordered frame window')
        if not (max(self.slow_build_count, self.slow_raster_count)
                <= self.slow_frame_count
                <= min(self.frame_count, self.slow_build_count + self.slow_raster_count)):
            raise ValueError('Inconsistent frame window')
        return self


# Literal values mirror PerformanceWireName in performance_trace_model.dart.
# Keep this allowlist static at runtime; never accept arbitrary client labels.
OperationWire = Literal[
    'app_startup', 'app_resume', 'conversation_open', 'message_send',
    'matrix_sync', 'media_load', 'recent_pictures_load', 'video_prepare', 'video_poster',
    'search', 'search_page_open', 'contacts_load', 'moments_load',
    'wallet_load', 'api_request', 'call_setup', 'call_active',
    'profile_load', 'chat_list_load', 'history_search',
    'keyboard_transition', 'room_local_frame',
]

PerformanceStageWire = Literal[
    'user_action', 'identity_lookup_done', 'local_room_lookup_done', 'route_enter', 'route_push_started',
    'first_frame_rendered', 'room_attach_started', 'room_attach_done', 'timeline_local_started', 'local_timeline_ready', 'remote_sync_ready', 'content_ready',
    'cache_load_started', 'cache_load_done', 'remote_refresh_started', 'remote_refresh_done', 'composer_submit',
    'outbox_persist', 'send_admission', 'matrix_send_start', 'matrix_send_finish', 'ack',
    'timeline_visible', 'timeline_published', 'sync_response_wait_started', 'sync_response_received', 'sync_processing_done', 'sync_cleanup_done', 'queue_entered',
    'queue_exited', 'shared_flight_joined', 'shared_flight_done', 'download_started', 'download_done', 'decrypt_started', 'decrypt_done',
    'decode_started', 'decode_done', 'video_selected', 'video_validated', 'video_prepare_started',
    'video_prepare_done', 'video_transcode_started', 'video_transcode_done', 'video_thumbnail_started', 'video_thumbnail_done', 'video_encrypted',
    'video_upload_started', 'video_upload_done', 'video_event_sent', 'call_start', 'signaling_ready',
    'ice_gathering', 'ice_connected', 'media_first_packet', 'call_connected', 'matrix_connected',
    'sync_finished', 'conversation_ready', 'local_search_started',
    'local_search_done', 'database_search_started', 'database_search_done', 'remote_search_started', 'remote_search_done',
    'render_results', 'request_finished',
    'search_scan_started', 'search_first_hit', 'search_coverage_complete',
    'keyboard_requested', 'keyboard_stable_frame', 'room_local_first_frame',
    'route_exit_requested', 'route_exit_frame',
    'fragment_write_started', 'fragment_write_done',
]

PerformanceResultWire = Literal[
    'success', 'slow', 'waiting_network', 'rejected', 'failed',
    'cancelled',
]

OpeningSourceWire = Literal[
    'local_room', 'pending_conversation',
]

PerformanceLifecycleWire = Literal[
    'foreground', 'background', 'resuming', 'unknown',
]

AppNetworkStateWire = Literal[
    'online', 'weak', 'offline', 'recovering', 'unknown',
]

MatrixStateWire = Literal[
    'connected', 'connecting', 'disconnected', 'unknown',
]

NetworkErrorWire = Literal[
    'dns_failure', 'connect_timeout', 'read_timeout', 'request_timeout', 'socket_failure', 'tls_failure',
    'offline', 'server5xx', 'rate_limit', 'auth_failure', 'business_rejection',
    'cancelled', 'unknown',
]

EndpointCategoryWire = Literal[
    'auth', 'profile', 'contacts', 'friendship', 'moments',
    'finance', 'support', 'push', 'media', 'diagnostics',
    'other',
]

HttpMethodWire = Literal[
    'get', 'post', 'put', 'patch', 'delete',
    'head', 'other',
]

CacheSourceWire = Literal[
    'memory', 'disk', 'network', 'miss', 'server_poster', 'local_frame', 'unknown',
]

MediaTypeWire = Literal[
    'image', 'video', 'audio', 'file', 'avatar',
    'unknown',
]

MediaPriorityWire = Literal[
    'interactive', 'visible', 'prefetch', 'background',
]

SizeBucketWire = Literal[
    'zero', 'tiny', 'small', 'medium', 'large',
    'huge', 'unknown',
]

DatabaseOperationWire = Literal[
    'timeline_local_load', 'conversation_snapshot_load', 'outbox_query',
    'media_index_lookup', 'message_search',
]

RowCountBucketWire = Literal[
    'zero', 'one_to_twenty', 'twenty_one_to_hundred',
    'hundred_one_to_five_hundred', 'over_five_hundred',
]

RelayProtocolWire = Literal[
    'udp', 'tcp', 'tls', 'unknown',
]


class PerformanceOperationStage(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    stage: PerformanceStageWire
    elapsed_ms: int = Field(ge=0, le=3600000)


_PERFORMANCE_FRAME_FIELDS = ('slow_frame_count', 'slow_build_count', 'slow_raster_count')
_SPAN_INDEX_SCHEMA = {
    'allOf': [
        {'if': {'required': ['attempt_index']}, 'then': {'properties': {
            'attempt_index': {'type': 'integer'},
            'operation': {'enum': ['video_prepare', 'message_send']},
        }}},
        {'if': {'required': ['window_index']}, 'then': {'properties': {
            'window_index': {'type': 'integer'}, 'operation': {'const': 'call_active'},
        }}},
        {'not': {'required': ['attempt_index', 'window_index']}},
    ],
}
_PERFORMANCE_FRAME_SCHEMA = {
    'oneOf': [
        {
            'required': list(_PERFORMANCE_FRAME_FIELDS),
            'properties': {
                'frame_attribution_complete': {'enum': [True, None]},
                **{field: {'type': 'integer'} for field in _PERFORMANCE_FRAME_FIELDS},
            },
        },
        {
            'required': ['frame_attribution_complete'],
            'properties': {'frame_attribution_complete': {'const': False}},
            'not': {'anyOf': [
                {'required': [field]} for field in _PERFORMANCE_FRAME_FIELDS
            ]},
        },
    ],
}


class _PerformanceMetadata(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    operation_id: str = Field(pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    operation: OperationWire
    stages: list[PerformanceOperationStage] = Field(max_length=64)
    lifecycle: PerformanceLifecycleWire
    attempt_index: int | None = Field(default=None, ge=0, le=20)
    window_index: int | None = Field(default=None, ge=0, le=1000000)
    soft_kick_count: int | None = Field(default=None, ge=0, le=1000)
    hard_restart_count: int | None = Field(default=None, ge=0, le=1000)
    sync_error_count: int | None = Field(default=None, ge=0, le=1000)
    reconnect_count: int | None = Field(default=None, ge=0, le=1000)
    last_healthy_sync_age_ms: int | None = Field(default=None, ge=0, le=3600000)
    opening_source: OpeningSourceWire | None = None
    app_network_state: AppNetworkStateWire | None = None
    matrix_state: MatrixStateWire | None = None
    transport_available: bool | None = None
    service_reachable: bool | None = None
    network_error: NetworkErrorWire | None = None
    endpoint_category: EndpointCategoryWire | None = None
    method: HttpMethodWire | None = None
    status_code: int | None = Field(default=None, ge=100, le=599)
    retry_count: int | None = Field(default=None, ge=0, le=20)
    cache_source: CacheSourceWire | None = None
    media_type: MediaTypeWire | None = None
    size_bucket: SizeBucketWire | None = None
    database_operation: DatabaseOperationWire | None = None
    row_count_bucket: RowCountBucketWire | None = None
    result_count_bucket: RowCountBucketWire | None = None
    scheduler_queue: int | None = Field(default=None, ge=0, le=1000)
    scheduler_active: int | None = Field(default=None, ge=0, le=1000)
    scheduler_video_active: int | None = Field(default=None, ge=0, le=1000)
    media_priority: MediaPriorityWire | None = None
    rtt_ms: float | None = Field(default=None, ge=0, le=60000, allow_inf_nan=False)
    jitter_ms: float | None = Field(default=None, ge=0, le=60000, allow_inf_nan=False)
    packet_loss_percent: float | None = Field(default=None, ge=0, le=100, allow_inf_nan=False)
    uses_turn: bool | None = None
    relay_protocol: RelayProtocolWire | None = None
    candidate_protocol: RelayProtocolWire | None = None
    restart_reason: Literal['query_changed', 'manual_refresh', 'safety_invalidation'] | None = None
    cancel_reason: Literal['new_query', 'route_closed', 'account_changed', 'visibility_revoked'] | None = None
    keyboard_direction: Literal['show', 'hide'] | None = None
    room_route_phase: Literal['enter', 'leave'] | None = None
    scan_page_count: int | None = Field(default=None, ge=0, le=100000)
    scan_row_count: int | None = Field(default=None, ge=0, le=10000000)
    first_hit_ms: int | None = Field(default=None, ge=0, le=3600000)
    full_coverage_ms: int | None = Field(default=None, ge=0, le=3600000)
    timeline_event_count: int | None = Field(default=None, ge=0, le=100000)

    @model_validator(mode='after')
    def consistent_span_indices(self):
        if 'attempt_index' in self.model_fields_set:
            if self.attempt_index is None or self.operation not in ('video_prepare', 'message_send'):
                raise ValueError('Attempt index requires a send operation')
        if 'window_index' in self.model_fields_set:
            if self.window_index is None or self.operation != 'call_active':
                raise ValueError('Window index requires an active call')
        if self.attempt_index is not None and self.window_index is not None:
            raise ValueError('Attempt and window indices are mutually exclusive')
        search_fields = {'restart_reason', 'cancel_reason', 'scan_page_count',
                         'scan_row_count', 'first_hit_ms', 'full_coverage_ms'}
        if self.operation != 'history_search' and self.model_fields_set & search_fields:
            raise ValueError('Search metadata requires history search')
        if self.operation == 'keyboard_transition':
            if self.keyboard_direction is None:
                raise ValueError('Keyboard transition requires direction')
        elif 'keyboard_direction' in self.model_fields_set:
            raise ValueError('Keyboard direction requires keyboard transition')
        if self.operation == 'room_local_frame':
            if self.room_route_phase is None:
                raise ValueError('Room frame requires route phase')
        elif 'room_route_phase' in self.model_fields_set:
            raise ValueError('Route phase requires room frame')
        if self.operation != 'matrix_sync' and 'timeline_event_count' in self.model_fields_set:
            raise ValueError('Timeline event count requires Matrix sync')
        return self


def _validate_stages(stages: list[PerformanceOperationStage], elapsed_ms: int) -> None:
    seen = set()
    previous_ms = -1
    for item in stages:
        if (item.stage in seen or item.elapsed_ms < previous_ms
                or item.elapsed_ms > elapsed_ms):
            raise ValueError('Inconsistent operation stages')
        seen.add(item.stage)
        previous_ms = item.elapsed_ms


class PerformanceOperation(_PerformanceMetadata):
    """Completed span. Missing kind preserves the original final protocol."""
    model_config = ConfigDict(extra='forbid', strict=True,
                              json_schema_extra={**_PERFORMANCE_FRAME_SCHEMA, **_SPAN_INDEX_SCHEMA})
    observation_kind: Literal['final'] = 'final'
    result: PerformanceResultWire
    total_ms: int = Field(ge=0, le=3600000)
    slow_frame_count: int | None = Field(default=None, ge=0, le=1000000)
    slow_build_count: int | None = Field(default=None, ge=0, le=1000000)
    slow_raster_count: int | None = Field(default=None, ge=0, le=1000000)
    frame_attribution_complete: bool | None = Field(
        default=None,
        description='Omit slow-frame counts when false; legacy records omit this field and include all counts.',
    )
    started_at_utc: str | None = Field(default=None, max_length=32, pattern=_UTC_TIME)
    ended_at_utc: str | None = Field(default=None, max_length=32, pattern=_UTC_TIME)
    clock_uncertainty_ms: int | None = Field(default=None, ge=0, le=2000)
    time_anchor_age_ms: int | None = Field(default=None, ge=0, le=300000)

    @model_validator(mode='after')
    def consistent_stages_and_frames(self):
        if self.frame_attribution_complete is False:
            if any(field in self.model_fields_set for field in _PERFORMANCE_FRAME_FIELDS):
                raise ValueError('Unconfirmed operation frame counts must be omitted')
        else:
            if any(getattr(self, field) is None for field in _PERFORMANCE_FRAME_FIELDS):
                raise ValueError('Complete operation frame counts are required')
            if not (max(self.slow_build_count, self.slow_raster_count)
                    <= self.slow_frame_count
                    <= self.slow_build_count + self.slow_raster_count):
                raise ValueError('Inconsistent operation frame counts')
        _validate_stages(self.stages, self.total_ms)
        fields = ('started_at_utc', 'ended_at_utc',
                  'clock_uncertainty_ms', 'time_anchor_age_ms')
        supplied = [name in self.model_fields_set for name in fields]
        if any(supplied):
            if not all(supplied) or any(getattr(self, name) is None for name in fields):
                raise ValueError('Incomplete calibrated time window')
            start = datetime.fromisoformat(self.started_at_utc.replace('Z', '+00:00'))
            end = datetime.fromisoformat(self.ended_at_utc.replace('Z', '+00:00'))
            wall_ms = (end - start).total_seconds() * 1000
            if wall_ms < 0 or abs(wall_ms - self.total_ms) > self.clock_uncertainty_ms + 1000:
                raise ValueError('Inconsistent calibrated duration')
        if (self.first_hit_ms is not None and self.first_hit_ms > self.total_ms
                or self.full_coverage_ms is not None and self.full_coverage_ms > self.total_ms
                or self.first_hit_ms is not None and self.full_coverage_ms is not None
                and self.first_hit_ms > self.full_coverage_ms):
            raise ValueError('Inconsistent search milestones')
        return self


class PerformanceObservation(_PerformanceMetadata):
    """Incomplete measurement; neither a duration sample nor a business result."""
    model_config = ConfigDict(extra='forbid', strict=True, json_schema_extra=_SPAN_INDEX_SCHEMA)
    observation_kind: Literal['checkpoint', 'expired']
    observed_elapsed_ms: int = Field(ge=0, le=3600000)
    frame_attribution_complete: bool = Field(json_schema_extra={'const': False})

    @model_validator(mode='after')
    def consistent_observation(self):
        if self.frame_attribution_complete is not False:
            raise ValueError('Incomplete observations cannot confirm frame attribution')
        _validate_stages(self.stages, self.observed_elapsed_ms)
        return self


NetworkCount = Annotated[int, Field(ge=0, le=1000000)]
UtcWindow = Annotated[str, Field(
    max_length=32,
    pattern=r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$')]


class DiagnosticNetwork(BaseModel):
    """Immutable, closed HTTP summary; no endpoint, user or location labels."""
    model_config = ConfigDict(extra='forbid', strict=True)
    sample_id: str = Field(pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    version: str = Field(max_length=32, pattern=r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$')
    platform: Literal['android', 'ios', 'other']
    window_start: UtcWindow
    window_end: UtcWindow
    target: Literal['primary_api']
    network: Literal['unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other']
    attempts: int = Field(ge=1, le=1000000)
    http_2xx: NetworkCount
    http_3xx: NetworkCount
    http_4xx: NetworkCount
    http_5xx: NetworkCount
    network_errors: NetworkCount
    timeouts: NetworkCount
    cancelled: NetworkCount
    success_latency_buckets: list[NetworkCount] = Field(min_length=9, max_length=9)

    @model_validator(mode='after')
    def consistent_summary(self):
        # Parse the constrained strings to reject impossible dates and compare
        # equivalent UTC spellings without replacing the original time window.
        start = datetime.fromisoformat(self.window_start.replace('Z', '+00:00'))
        end = datetime.fromisoformat(self.window_end.replace('Z', '+00:00'))
        if start > end:
            raise ValueError('Unordered diagnostic window')
        outcomes = (self.http_2xx, self.http_3xx, self.http_4xx, self.http_5xx,
                    self.network_errors, self.timeouts, self.cancelled)
        if sum(outcomes) != self.attempts:
            raise ValueError('Inconsistent attempt counts')
        if sum(self.success_latency_buckets) != self.http_2xx:
            raise ValueError('Inconsistent success buckets')
        return self


class DiagnosticBatch(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    version: str = Field(max_length=32, pattern=r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$')
    platform: Literal['android', 'ios', 'other']
    events: list[DiagnosticEvent] = Field(default_factory=list, max_length=20)
    frames: DiagnosticFrames | None = None
    frame_windows: list[DiagnosticFrameWindow] | None = Field(default=None, min_length=1, max_length=8)
    diagnostic_loss: DiagnosticLoss | None = None
    operations: list[PerformanceOperation | PerformanceObservation] = Field(default_factory=list, max_length=20)
    networks: list[DiagnosticNetwork] | None = Field(default=None, max_length=8)
    network_requests: list[NetworkRequestDiagnostic] | None = Field(default=None, max_length=8)

    @model_validator(mode='after')
    def nonempty(self):
        if not self.events and self.frames is None and not self.frame_windows and self.diagnostic_loss is None and not self.operations and not self.networks and not self.network_requests:
            raise ValueError('Empty diagnostic batch')
        if len(self.events) + len(self.operations) + len(self.network_requests or []) > 20:
            raise ValueError('Diagnostic record budget exceeded')
        sample_ids = [item.sample_id for item in self.networks or []]
        if len(sample_ids) != len(set(sample_ids)):
            raise ValueError('Duplicate network samples')
        request_ids = [item.request_id for item in self.network_requests or []]
        if len(request_ids) != len(set(request_ids)):
            raise ValueError('Duplicate request records')
        window_ids = [item.window_id for item in self.frame_windows or []]
        if len(window_ids) != len(set(window_ids)):
            raise ValueError('Duplicate frame windows')
        return self


class DiagnosticReceipt(BaseModel):
    accepted: int


def write_diagnostic_line(line: bytes) -> None:
    """Submit the bounded JSON and newline together to unbuffered stdout."""
    stream = sys.stdout.buffer
    remaining = memoryview(line)
    while remaining:
        written = stream.write(remaining)
        if written is None or written <= 0:
            raise OSError('Diagnostic stdout write made no progress')
        remaining = remaining[written:]
    stream.flush()


async def read_bounded_body(request: Request) -> bytes:
    # Content-Length is advisory: chunked/dishonest clients get the same limit.
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BODY_BYTES:
            raise AppError(code='DIAGNOSTICS_TOO_LARGE', message='诊断批次过大', status_code=413)
        body.extend(chunk)
    return bytes(body)


def _request_schema():
    # Request is streamed manually so FastAPI must not eagerly parse its body.
    # Inline the small model definitions for a self-contained OpenAPI schema.
    schema = DiagnosticBatch.model_json_schema()
    definitions = schema.pop('$defs', {})

    def expand(value):
        if isinstance(value, dict):
            if '$ref' in value:
                return expand(definitions[value['$ref'].rsplit('/', 1)[1]])
            return {key: expand(item) for key, item in value.items()}
        if isinstance(value, list):
            return [expand(item) for item in value]
        return value

    return expand(schema)


def create_client_diagnostics_router(settings: Settings, session_factory, rate_limiter: RateLimiter) -> APIRouter:
    router = APIRouter(tags=['client-diagnostics'])
    configured_secret = settings.diagnostic_identity_secret
    if (settings.environment != 'production' and configured_secret is not None
            and not configured_secret.get_secret_value().strip()):
        configured_secret = None
    if settings.environment == 'production' and configured_secret is None:
        raise ValueError('BUSINESS_DIAGNOSTIC_IDENTITY_SECRET is required')
    identity_key = (configured_secret.get_secret_value().encode('utf-8')
                    if configured_secret is not None else secrets.token_bytes(32))
    if len(identity_key) < 32:
        raise ValueError('BUSINESS_DIAGNOSTIC_IDENTITY_SECRET is too short')
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')

    def actor(authorization: Annotated[str | None, Header()] = None) -> dict:
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return tokens.decode_access_token(authorization[7:])

    @router.post('/client-diagnostics', status_code=202, response_model=DiagnosticReceipt,
        responses={401: {'description': 'Authentication required'},
                   413: {'description': 'Maximum 16384 body bytes'},
                   422: {'description': 'Closed metadata schema rejected'},
                   429: {'description': 'Account or source limit reached'}},
        openapi_extra={'requestBody': {'required': True, 'content': {
            'application/json': {'schema': _request_schema()}}}})
    async def ingest(request: Request, claims: dict = Depends(actor)):
        # Hash only for limiter storage; identifiers/IP never enter the log.
        # Ignore attacker-controlled forwarded headers.
        user_id = str(claims['sub'])
        source = request.client.host if request.client else 'unknown'
        for dimension, value, limit in [('account', user_id, 1), ('ip', source, 30)]:
            digest = hashlib.sha256(value.encode()).hexdigest()
            await run_in_threadpool(rate_limiter.hit, f'client-diagnostics:{dimension}:{digest}',
                                    limit=limit, window_seconds=60)
        raw = await read_bounded_body(request)
        try:
            batch = DiagnosticBatch.model_validate_json(raw)
        except ValidationError:
            # Do not echo input, arbitrary field names or validation contexts.
            raise AppError(code='DIAGNOSTICS_INVALID', message='诊断格式无效', status_code=422) from None
        safe = {'event': 'client_diagnostics', **batch.model_dump(mode='json', exclude_unset=True)}
        safe['subject_ref'] = diagnostic_ref(identity_key, 'subject', user_id)
        if claims.get('device_id'):
            safe['device_ref'] = diagnostic_ref(identity_key, 'device', str(claims['device_id']))
        # Container stdout uses the deployment's bounded log rotation. Never
        # write credentials, account/room IDs, bodies or arbitrary exceptions.
        line = (json.dumps(safe, ensure_ascii=True, separators=(',', ':')) + '\n').encode('ascii')
        await run_in_threadpool(write_diagnostic_line, line)
        return DiagnosticReceipt(accepted=len(batch.events) + len(batch.operations) + len(batch.network_requests or []))

    return router
