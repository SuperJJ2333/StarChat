"""Bounded, authenticated client reliability metadata; never accept free text."""
import hashlib
import json
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings
from app.core.errors import AppError
from app.core.rate_limits import RateLimiter
from app.modules.identity.tokens import TokenService

MAX_BODY_BYTES = 16384


class DiagnosticEvent(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    operation_id: str = Field(pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    stage: Literal['sendAdmission', 'matrixSend', 'historyLoad', 'historySearch',
                   'dateMonth', 'dateLocate', 'scrollAnchor', 'framework',
                   'pending_write_failed', 'request_uncertain', 'result_write_failed',
                   'retry_recovered', 'terminal_invalidated', 'result_superseded']
    error: Literal['slow', 'network', 'timeout', 'rejected', 'cancelled', 'incomplete', 'unknown', 'recovered']
    elapsed_ms: int = Field(ge=0, le=3600000)
    count: int = Field(ge=1, le=1000000)
    status: int | None = Field(default=None, ge=100, le=599)
    retry_count: int | None = Field(default=None, ge=0, le=20)
    lifecycle: Literal['foreground', 'background', 'unknown'] | None = None


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


# Literal values mirror PerformanceWireName in performance_trace_model.dart.
# Keep this allowlist static at runtime; never accept arbitrary client labels.
OperationWire = Literal[
    'app_startup', 'app_resume', 'conversation_open', 'message_send',
    'matrix_sync', 'media_load', 'recent_pictures_load', 'video_prepare', 'video_poster',
    'search', 'search_page_open', 'contacts_load', 'moments_load',
    'wallet_load', 'api_request', 'call_setup', 'call_active',
    'profile_load', 'chat_list_load',
]

PerformanceStageWire = Literal[
    'user_action', 'identity_lookup_done', 'local_room_lookup_done', 'route_enter', 'route_push_started',
    'first_frame_rendered', 'room_attach_started', 'room_attach_done', 'timeline_local_started', 'local_timeline_ready', 'remote_sync_ready', 'content_ready',
    'cache_load_started', 'cache_load_done', 'remote_refresh_started', 'remote_refresh_done', 'composer_submit',
    'outbox_persist', 'send_admission', 'matrix_send_start', 'matrix_send_finish', 'ack',
    'timeline_visible', 'sync_response_wait_started', 'sync_response_received', 'sync_processing_done', 'sync_cleanup_done', 'queue_entered',
    'queue_exited', 'shared_flight_joined', 'shared_flight_done', 'download_started', 'download_done', 'decrypt_started', 'decrypt_done',
    'decode_started', 'decode_done', 'video_selected', 'video_validated', 'video_prepare_started',
    'video_prepare_done', 'video_transcode_started', 'video_transcode_done', 'video_thumbnail_done', 'video_encrypted',
    'video_upload_started', 'video_upload_done', 'video_event_sent', 'call_start', 'signaling_ready',
    'ice_gathering', 'ice_connected', 'media_first_packet', 'call_connected', 'matrix_connected',
    'sync_finished', 'conversation_ready', 'local_search_started',
    'local_search_done', 'database_search_started', 'database_search_done', 'remote_search_started', 'remote_search_done',
    'render_results', 'request_finished',
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
    'dns_failure', 'connect_timeout', 'read_timeout', 'socket_failure', 'tls_failure',
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


class PerformanceOperation(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True,
                              json_schema_extra=_PERFORMANCE_FRAME_SCHEMA)
    operation_id: str = Field(pattern=r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    operation: OperationWire
    result: PerformanceResultWire
    total_ms: int = Field(ge=0, le=3600000)
    stages: list[PerformanceOperationStage] = Field(max_length=64)
    lifecycle: PerformanceLifecycleWire
    slow_frame_count: int | None = Field(default=None, ge=0, le=1000000)
    slow_build_count: int | None = Field(default=None, ge=0, le=1000000)
    slow_raster_count: int | None = Field(default=None, ge=0, le=1000000)
    frame_attribution_complete: bool | None = Field(
        default=None,
        description='Omit slow-frame counts when false; legacy records omit this field and include all counts.',
    )
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
        seen = set()
        previous_ms = -1
        for item in self.stages:
            if (item.stage in seen or item.elapsed_ms < previous_ms
                    or item.elapsed_ms > self.total_ms):
                raise ValueError('Inconsistent operation stages')
            seen.add(item.stage)
            previous_ms = item.elapsed_ms
        return self


class DiagnosticBatch(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    version: str = Field(max_length=32, pattern=r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$')
    platform: Literal['android', 'ios', 'other']
    events: list[DiagnosticEvent] = Field(default_factory=list, max_length=20)
    frames: DiagnosticFrames | None = None
    operations: list[PerformanceOperation] = Field(default_factory=list, max_length=20)

    @model_validator(mode='after')
    def nonempty(self):
        if not self.events and self.frames is None and not self.operations:
            raise ValueError('Empty diagnostic batch')
        return self


class DiagnosticReceipt(BaseModel):
    accepted: int


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
    tokens = TokenService(session_factory,
        jwt_secret=settings.jwt_secret or 'development-jwt-secret-at-least-thirty-two-bytes',
        jwt_issuer=settings.jwt_issuer, require_session_claims=settings.environment != 'test')

    def actor(authorization: Annotated[str | None, Header()] = None) -> str:
        if not authorization or not authorization.startswith('Bearer '):
            raise AppError(code='AUTH_REQUIRED', message='需要登录', status_code=401)
        return str(tokens.decode_access_token(authorization[7:])['sub'])

    @router.post('/client-diagnostics', status_code=202, response_model=DiagnosticReceipt,
        responses={401: {'description': 'Authentication required'},
                   413: {'description': 'Maximum 16384 body bytes'},
                   422: {'description': 'Closed metadata schema rejected'},
                   429: {'description': 'Account or source limit reached'}},
        openapi_extra={'requestBody': {'required': True, 'content': {
            'application/json': {'schema': _request_schema()}}}})
    async def ingest(request: Request, user_id: str = Depends(actor)):
        # Hash only for limiter storage; identifiers/IP never enter the log.
        # Ignore attacker-controlled forwarded headers.
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
        # Container stdout uses the deployment's bounded log rotation. Never
        # write credentials, account/room IDs, bodies or arbitrary exceptions.
        await run_in_threadpool(print, json.dumps(safe, ensure_ascii=True, separators=(',', ':')), flush=True)
        return DiagnosticReceipt(accepted=len(batch.events) + len(batch.operations))

    return router
