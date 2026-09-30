import asyncio
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.core.config import Settings
from app.core.errors import AppError, install_error_handlers
from app.main import create_app

NOW = datetime(2026, 9, 27, 7, 0, tzinfo=timezone.utc)


def payload(**changes):
    return {'schema': 1, 'platform': 'ios', 'event_id': str(uuid4()),
            'occurred_at': NOW.isoformat().replace('+00:00', 'Z'),
            'app_version': '0.4.15', 'build': 2185, 'os_version': '18.6.1',
            'stage': 'matrix_preflight', 'boundary': 'database_open',
            'category': 'database', 'count': 1, **changes}


def test_app_registers_independent_startup_route():
    app = create_app(Settings(environment='test', database_url='sqlite+pysqlite:///:memory:'),
                     startup_diagnostics_admission=Admission())
    response = TestClient(app).post('/api/v1/startup-diagnostics', json={})
    assert response.status_code == 422


class Admission:
    def __init__(self):
        self.calls = []
        self.source_calls = []
        self.completed = set()
        self.pending = set()
        self.failure = False
        self.complete_failure = False
        self.result = None

    def admit(self, event_id, source):
        self.check_source(source)
        return self.reserve(event_id)

    def check_source(self, source):
        self.source_calls.append(source)
        if self.failure:
            raise RuntimeError('PRIVATE_SECRET')
        return len(self.source_calls) <= 10

    def reserve(self, event_id):
        self.calls.append(event_id)
        if self.failure:
            raise RuntimeError('PRIVATE_SECRET')
        if self.result:
            return self.result
        if event_id in self.completed:
            return 'duplicate', None
        if event_id in self.pending:
            return 'busy', None
        self.pending.add(event_id)
        return 'new', 'lease-token'

    def complete(self, event_id, token):
        if self.complete_failure:
            raise RuntimeError('PRIVATE_SECRET')
        self.pending.remove(event_id)
        self.completed.add(event_id)
        return True

    def release(self, event_id, token):
        self.pending.discard(event_id)


@pytest.fixture
def endpoint():
    from app.api.startup_diagnostics import create_startup_diagnostics_router
    admission = Admission()
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_startup_diagnostics_router(admission, clock=lambda: NOW), prefix='/api/v1')
    return TestClient(app), admission


def test_anonymous_closed_report_and_completed_duplicate(endpoint, capsys):
    client, admission = endpoint
    data = payload(category='protected_data', preflight_cause='missingKey', native_status=-25308, login_stage='L04')
    for _ in range(2):
        response = client.post('/api/v1/startup-diagnostics', json=data)
        assert response.status_code == 202
        assert response.json() == {'accepted': True, 'event_id': data['event_id']}
    logs = capsys.readouterr().out.splitlines()
    assert len(logs) == 1
    assert json.loads(logs[0]) == {'type': 'startup_diagnostics', **data}
    assert data['event_id'] in admission.completed


@pytest.mark.parametrize('changes', [
    {'token': 'PRIVATE_SECRET'}, {'device_id': 'PRIVATE_SECRET'}, {'exception': 'PRIVATE_SECRET'},
    {'schema': True}, {'schema': 1.0}, {'schema': '1'}, {'schema': 2}, {'platform': 'android'},
    {'event_id': '00000000-0000-1000-8000-000000000000'}, {'event_id': 'PRIVATE_SECRET'},
    {'app_version': '0.4.15+2185'}, {'app_version': 'v0.4.15'}, {'app_version': '1.2'},
    {'app_version': '1.2.3\n'}, {'app_version': '9' * 100 + '.2.3'},
    {'build': True}, {'build': 1.0}, {'build': '1'}, {'build': 0}, {'build': 10000001},
    {'count': True}, {'count': '1'}, {'count': 1.0}, {'count': 0}, {'count': 101},
    {'os_version': '18.1.2.3'}, {'os_version': 'iOS 18.1'}, {'os_version': '1234'},
    {'stage': 'PRIVATE_SECRET'}, {'boundary': 'PRIVATE_SECRET'}, {'category': 'PRIVATE_SECRET'},
    {'preflight_cause': 'missing_key'}, {'native_status': -999}, {'native_status': True},
    {'native_status': -50.0}, {'native_status': '-50'}, {'native_status': 'absent'},
    {'login_stage': 'L09'}, {'login_stage': 4},
    {'occurred_at': '2026-09-27T07:00:01Z'}, {'occurred_at': '2026-09-27T07:00:00.0Z'},
    {'occurred_at': '2026-09-27T07:00:00+08:00'}, {'occurred_at': '2026-09-27T07:00Z'},
    {'occurred_at': '2026-02-30T07:00:00Z'},
    {'occurred_at': (NOW - timedelta(days=1, minutes=1)).isoformat()},
    {'occurred_at': (NOW + timedelta(minutes=6)).isoformat()},
])
def test_rejects_invalid_or_private_input_without_echo_logs_or_admission(endpoint, capsys, changes):
    client, admission = endpoint
    response = client.post('/api/v1/startup-diagnostics', json=payload(**changes))
    assert response.status_code == 422
    assert 'PRIVATE_SECRET' not in response.text
    assert response.json()['error']['fields'] == []
    assert capsys.readouterr().out == ''
    assert admission.calls == []


@pytest.mark.parametrize('changes', [
    {'os_version': 'unknown'}, {'native_status': 'other', 'category': 'platform'}, {'native_status': None},
    {'preflight_cause': None, 'login_stage': None}, {'native_status': -50, 'category': 'platform'},
    {'occurred_at': (NOW - timedelta(days=1)).isoformat()},
    {'occurred_at': (NOW + timedelta(minutes=5)).isoformat()},
])
def test_accepts_closed_optional_and_time_boundaries(endpoint, changes):
    assert endpoint[0].post('/api/v1/startup-diagnostics', json=payload(**changes)).status_code == 202


def test_body_limit_ignores_dishonest_length_and_chunking(endpoint, capsys):
    from app.api.startup_diagnostics import read_bounded_body
    client, admission = endpoint
    assert client.post('/api/v1/startup-diagnostics', content=b' ' * 4097,
                       headers={'Content-Length': '1'}).status_code == 413
    chunks = iter([{'type': 'http.request', 'body': b'x' * 3000, 'more_body': True},
                   {'type': 'http.request', 'body': b'x' * 1097, 'more_body': False}])
    async def receive():
        return next(chunks)
    request = Request({'type': 'http', 'headers': []}, receive)
    with pytest.raises(AppError) as error:
        asyncio.run(read_bounded_body(request))
    assert error.value.status_code == 413
    assert admission.calls == []
    assert capsys.readouterr().out == ''


def test_source_uses_connection_and_never_forwarded_headers(endpoint, capsys):
    client, admission = endpoint
    response = client.post('/api/v1/startup-diagnostics', json=payload(), headers={
        'X-Forwarded-For': 'PRIVATE_SECRET', 'X-Real-IP': 'PRIVATE_SECRET',
        'Forwarded': 'for=PRIVATE_SECRET', 'Authorization': 'Bearer PRIVATE_SECRET'})
    assert response.status_code == 202
    assert admission.source_calls == ['testclient']
    assert 'PRIVATE_SECRET' not in capsys.readouterr().out


@pytest.mark.parametrize('outcome,code', [('busy', 503), ('limited', 429)])
def test_pending_and_limits_do_not_log(endpoint, capsys, outcome, code):
    client, admission = endpoint
    admission.result = outcome, None
    assert client.post('/api/v1/startup-diagnostics', json=payload()).status_code == code
    assert capsys.readouterr().out == ''


def test_dependency_failure_returns_generic_503(endpoint, capsys):
    client, admission = endpoint
    admission.failure = True
    response = client.post('/api/v1/startup-diagnostics', json=payload())
    assert response.status_code == 503
    assert 'PRIVATE_SECRET' not in response.text
    assert capsys.readouterr().out == ''


def test_emitter_app_error_is_not_reflected_or_logged(capsys):
    from app.api.startup_diagnostics import create_startup_diagnostics_router
    def emit(_):
        raise AppError(code='PRIVATE_SECRET', message='PRIVATE_SECRET', status_code=400)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_startup_diagnostics_router(Admission(), clock=lambda: NOW, emit=emit))
    response = TestClient(app).post('/startup-diagnostics', json=payload())
    assert response.status_code == 503
    assert 'PRIVATE_SECRET' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('raw', [b'{"schema":1,"schema":1}', b'[' * 1900 + b']' * 1900,
                               b'\xff', b'NaN', b'{"token":"PRIVATE_SECRET"}'])
def test_malformed_json_is_generic_422(endpoint, capsys, raw):
    response = endpoint[0].post('/api/v1/startup-diagnostics', content=raw)
    assert response.status_code == 422
    assert 'PRIVATE_SECRET' not in response.text
    assert capsys.readouterr().out == ''


def test_print_failure_releases_pending_and_retry_accepts():
    from app.api.startup_diagnostics import create_startup_diagnostics_router
    admission = Admission()
    emitted = []
    def emit(report):
        if not emitted:
            emitted.append('failed')
            raise RuntimeError('PRIVATE_SECRET')
        emitted.append(report)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_startup_diagnostics_router(admission, clock=lambda: NOW, emit=emit))
    data = payload()
    client = TestClient(app)
    response = client.post('/startup-diagnostics', json=data)
    assert response.status_code == 503
    assert not admission.pending and not admission.completed
    assert 'PRIVATE_SECRET' not in response.text
    assert client.post('/startup-diagnostics', json=data).status_code == 202


def test_completion_failure_does_not_acknowledge(endpoint, capsys):
    client, admission = endpoint
    admission.complete_failure = True
    data = payload()
    response = client.post('/api/v1/startup-diagnostics', json=data)
    assert response.status_code == 503
    assert not admission.completed and not admission.pending
    assert 'PRIVATE_SECRET' not in response.text
    assert len(capsys.readouterr().out.splitlines()) == 1


def test_real_application_accepts_anonymous_report_and_keeps_old_auth(capsys):
    data = payload(occurred_at=datetime.now(timezone.utc).replace(second=0, microsecond=0).isoformat())
    app = create_app(Settings(environment='test', database_url='sqlite+pysqlite:///:memory:'),
                     startup_diagnostics_admission=Admission())
    client = TestClient(app)
    response = client.post('/api/v1/startup-diagnostics', json=data)
    assert response.status_code == 202
    assert response.json() == {'accepted': True, 'event_id': data['event_id']}
    assert client.post('/api/v1/client-diagnostics', json={}).status_code == 401
    assert len(capsys.readouterr().out.splitlines()) == 1


def test_openapi_exposes_closed_anonymous_contract():
    from scripts.export_openapi import build_document
    document = build_document()
    operation = document['paths']['/api/v1/startup-diagnostics']['post']
    assert operation.get('security', []) == []
    schema = operation['requestBody']['content']['application/json']['schema']
    assert schema['additionalProperties'] is False
    assert len(schema['properties']['boundary']['enum']) == 30
    assert {'413', '422', '429', '503'} <= set(operation['responses'])
    assert document['paths']['/api/v1/client-diagnostics']['post']['security'] == [{'bearerAuth': []}]


def test_invalid_requests_consume_source_budget_before_body_validation(endpoint):
    client, admission = endpoint
    for _ in range(10):
        assert client.post('/api/v1/startup-diagnostics', json={'secret': 'PRIVATE_SECRET'}).status_code == 422
    response = client.post('/api/v1/startup-diagnostics', content=b' ' * 4097)
    assert response.status_code == 429
    assert len(admission.source_calls) == 11
    assert not admission.calls


def test_startup_endpoint_never_echoes_caller_trace_id(capsys):
    app = create_app(Settings(environment='test', database_url='sqlite+pysqlite:///:memory:'),
                     startup_diagnostics_admission=Admission())
    response = TestClient(app).post('/api/v1/startup-diagnostics', json={},
                                    headers={'X-Trace-Id': 'PRIVATE_SECRET'})
    assert response.status_code == 422
    assert 'PRIVATE_SECRET' not in response.text
    assert 'PRIVATE_SECRET' not in str(response.headers)
    captured = capsys.readouterr()
    assert 'PRIVATE_SECRET' not in captured.out + captured.err


@pytest.mark.parametrize('suffix,status', [('', 422), ('/', 307)])
def test_startup_endpoint_discards_all_caller_correlation_headers(capsys, suffix, status):
    app = create_app(Settings(environment='test', database_url='sqlite+pysqlite:///:memory:'),
                     startup_diagnostics_admission=Admission())
    performance_id = '01234567-89ab-4cde-8123-456789abcdef'
    request_id = '01234567-89ab-4cde-8123-456789abcdee'
    response = TestClient(app).post('/api/v1/startup-diagnostics' + suffix, json={},
                                    follow_redirects=False, headers={
                                        'X-Trace-Id': 'PRIVATE_SECRET',
                                        'X-ChatFlow-Performance-Id': performance_id,
                                        'X-ChatFlow-Request-Id': request_id,
                                    })
    assert response.status_code == status
    assert 'PRIVATE_SECRET' not in str(response.headers)
    snapshot = app.state.request_latency_metrics.snapshot()
    assert snapshot['recent_operation_requests'] == []
    captured = capsys.readouterr()
    assert all(value not in captured.out + captured.err
               for value in ('PRIVATE_SECRET', performance_id, request_id))


@pytest.mark.parametrize('category', ['metadata', 'database', 'filesystem', 'matrix_identity',
                                    'matrix_credentials', 'matrix_rejected', 'matrix_rate_limited',
                                    'matrix_service', 'network', 'unknown'])
@pytest.mark.parametrize('native_status', [-25308, 'other'])
def test_native_status_rejected_for_nonplatform_categories(endpoint, capsys, category, native_status):
    client, admission = endpoint
    response = client.post('/api/v1/startup-diagnostics', json=payload(
        category=category, native_status=native_status))
    assert response.status_code == 422
    assert not admission.calls
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('category', ['platform', 'protected_data', 'keychain_permission'])
@pytest.mark.parametrize('native_status', [-25308, -34018, -25291, -25300, -50, 'other'])
def test_native_status_accepted_for_platform_categories(endpoint, category, native_status):
    response = endpoint[0].post('/api/v1/startup-diagnostics', json=payload(
        category=category, native_status=native_status))
    assert response.status_code == 202


@pytest.mark.parametrize('category', ['metadata', 'database', 'filesystem', 'matrix_identity',
                                    'matrix_credentials', 'matrix_rejected', 'matrix_rate_limited',
                                    'matrix_service', 'network', 'unknown'])
def test_null_or_absent_native_status_accepted_for_nonplatform_categories(endpoint, category):
    client, _ = endpoint
    assert client.post('/api/v1/startup-diagnostics', json=payload(category=category)).status_code == 202
    assert client.post('/api/v1/startup-diagnostics', json=payload(
        category=category, native_status=None)).status_code == 202


def test_openapi_documents_native_status_category_constraint():
    from scripts.export_openapi import build_document
    operation = build_document()['paths']['/api/v1/startup-diagnostics']['post']
    schema = operation['requestBody']['content']['application/json']['schema']
    assert schema.get('allOf') == [{
        'if': {'required': ['native_status'], 'properties': {'native_status': {'not': {'type': 'null'}}}},
        'then': {'properties': {'category': {'enum': ['platform', 'protected_data', 'keychain_permission']}}},
    }]
