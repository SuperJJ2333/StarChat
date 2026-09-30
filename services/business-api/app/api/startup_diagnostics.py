"""Closed anonymous iOS startup metadata; no session or identity dependencies."""
import json
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator
from starlette.concurrency import run_in_threadpool
from starlette.requests import ClientDisconnect

from app.core.errors import AppError
from app.core.startup_diagnostics_admission import StartupDiagnosticsAdmission

MAX_BODY_BYTES = 4096
UUID4_PATTERN = r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'


class StartupDiagnosticReport(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True, populate_by_name=False,
                              json_schema_extra={'allOf': [{
                                  'if': {'required': ['native_status'], 'properties': {
                                      'native_status': {'not': {'type': 'null'}}}},
                                  'then': {'properties': {'category': {'enum': [
                                      'platform', 'protected_data', 'keychain_permission']}}},
                              }]})
    schema_version: Literal[1] = Field(alias='schema')
    platform: Literal['ios']
    event_id: str = Field(min_length=36, max_length=36, pattern=UUID4_PATTERN)
    occurred_at: str = Field(max_length=25, pattern=r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:00(Z|\+00:00)$')
    app_version: str = Field(max_length=14, pattern=r'^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$')
    build: int = Field(ge=1, le=10000000)
    os_version: str = Field(max_length=11, pattern=r'^([0-9]{1,3}(\.[0-9]{1,3}){0,2}|unknown)$')
    stage: Literal['initialization', 'installation_check', 'diagnostic_salt',
                   'installation_identity', 'matrix_preflight', 'start_application',
                   'session_bootstrap', 'local_restore']
    boundary: Literal['version_load', 'preferences_load', 'marker_read', 'protected_data_probe',
                      'container_probe', 'marker_register', 'installation_cleanup', 'reconcile',
                      'diagnostic_salt', 'installation_identity', 'identity_snapshot',
                      'database_presence', 'database_header', 'database_identity_read',
                      'olm_identity_check', 'original_identity_search', 'database_key',
                      'database_open', 'client_migration', 'application_start', 'local_identity',
                      'matrix_grant', 'switch_local_clear', 'matrix_login', 'matrix_sync',
                      'identity_binding', 'account_storage', 'matrix_session', 'local_restore',
                      'bootstrap']
    category: Literal['protected_data', 'keychain_permission', 'platform', 'metadata', 'database',
                      'filesystem', 'matrix_identity', 'matrix_credentials', 'matrix_rejected',
                      'matrix_rate_limited', 'matrix_service', 'network', 'unknown']
    preflight_cause: Literal['missingDatabaseWithBinding', 'missingDatabaseWithKey', 'missingKey',
                            'missingOlmAccount', 'fingerprintMismatch', 'identityMismatch',
                            'unreadable', 'originalIdentityElsewhere', 'multipleCandidates',
                            'recoveryPending', 'legacyPlaintextMigrationDeferred'] | None = None
    native_status: Literal[-25308, -34018, -25291, -25300, -50, 'other'] | None = None
    login_stage: Literal['L01', 'L02', 'L03', 'L04', 'L05', 'L06', 'L07', 'L08'] | None = None
    count: int = Field(ge=1, le=100)

    @field_validator('schema_version', 'build', 'count', mode='before')
    @classmethod
    def strict_integer(cls, value):
        # Literal[1] otherwise accepts True/1.0 through Python equality.
        if type(value) is not int:
            raise ValueError('Invalid integer')
        return value

    @field_validator('native_status', mode='before')
    @classmethod
    def strict_native_status(cls, value):
        if value is not None and type(value) not in (str, int):
            raise ValueError('Invalid native status')
        return value

    @field_validator('occurred_at')
    @classmethod
    def real_utc_minute(cls, value):
        datetime.fromisoformat(value.replace('Z', '+00:00'))
        return value

    @model_validator(mode='after')
    def native_status_requires_platform_category(self):
        if self.native_status is not None and self.category not in (
                'platform', 'protected_data', 'keychain_permission'):
            raise ValueError('Native status requires a platform category')
        return self


class StartupDiagnosticReceipt(BaseModel):
    accepted: Literal[True]
    event_id: str = Field(pattern=UUID4_PATTERN)


def _rejected(status: int) -> AppError:
    return AppError(code=f'STARTUP_DIAGNOSTICS_{status}',
                    message='Startup diagnostics request rejected', status_code=status)


async def read_bounded_body(request: Request) -> bytes:
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > MAX_BODY_BYTES:
            raise _rejected(413)
        body.extend(chunk)
    return bytes(body)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key')
        result[key] = value
    return result


def _emit(report: dict) -> None:
    print(json.dumps({'type': 'startup_diagnostics', **report}, separators=(',', ':'),
                     ensure_ascii=True), flush=True)


def create_startup_diagnostics_router(
    admission: StartupDiagnosticsAdmission, *, clock=None, emit=None,
) -> APIRouter:
    router = APIRouter(tags=['startup-diagnostics'])
    clock = clock or (lambda: datetime.now(timezone.utc))
    emit = emit or _emit

    def receive(report: StartupDiagnosticReport):
        token = None
        try:
            result, token = admission.reserve(report.event_id)
            if result == 'limited':
                raise _rejected(429)
            if result == 'busy':
                raise _rejected(503)
            if result == 'new' and token:
                emit(report.model_dump(by_alias=True, exclude_unset=True))
                if not admission.complete(report.event_id, token):
                    raise _rejected(503)
            elif result != 'duplicate':
                raise _rejected(503)
        except Exception as error:
            if token:
                try:
                    admission.release(report.event_id, token)
                except Exception:
                    pass  # Short lease permits retry if the dependency remains unavailable.
            if (isinstance(error, AppError) and error.status_code in (429, 503)
                    and error.code == f'STARTUP_DIAGNOSTICS_{error.status_code}'):
                raise _rejected(error.status_code) from None
            raise _rejected(503) from None
        return {'accepted': True, 'event_id': report.event_id}

    @router.post('/startup-diagnostics', status_code=202, response_model=StartupDiagnosticReceipt,
                 responses={413: {'description': 'Maximum 4096 body bytes'},
                            422: {'description': 'Closed metadata schema rejected'},
                            429: {'description': 'Global, connection source or capacity limit'},
                            503: {'description': 'Dependency failure or event pending'}},
                 openapi_extra={'security': [], 'requestBody': {'required': True, 'content': {
                     'application/json': {'schema': StartupDiagnosticReport.model_json_schema()}}}})
    async def ingest(request: Request):
        # Charge all requests, including malformed or oversize bodies, once.
        # Global-first atomic limit prevents source-key cardinality abuse.
        source = request.client.host if request.client else 'unknown'
        try:
            allowed = await run_in_threadpool(admission.check_source, source)
        except Exception:
            raise _rejected(503) from None
        if not allowed:
            raise _rejected(429)
        try:
            body = await read_bounded_body(request)
            report = StartupDiagnosticReport.model_validate(json.loads(body, object_pairs_hook=_unique_object))
            occurred = datetime.fromisoformat(report.occurred_at.replace('Z', '+00:00'))
            now = clock()
            if occurred < now - timedelta(hours=24) or occurred > now + timedelta(minutes=5):
                raise ValueError('Invalid observation time')
        except (ValidationError, ValueError, UnicodeError, ClientDisconnect, RecursionError):
            raise _rejected(422) from None
        return await run_in_threadpool(receive, report)

    return router
