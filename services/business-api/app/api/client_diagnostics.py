"""Bounded, authenticated client reliability metadata; never accept free text."""
import hashlib
import json
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError
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


class DiagnosticBatch(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    version: str = Field(max_length=32, pattern=r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$')
    platform: Literal['android', 'ios', 'other']
    events: list[DiagnosticEvent] = Field(min_length=1, max_length=20)


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
        return DiagnosticReceipt(accepted=len(batch.events))

    return router
