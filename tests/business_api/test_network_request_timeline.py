"""The timeline measures ASGI boundaries and does not block request execution."""
import asyncio
import importlib
import json
from threading import Event
import time
from uuid import uuid4
from contextvars import ContextVar

from fastapi import FastAPI
from starlette.routing import Route
import pytest

from app.core.tracing import RequestLatencyMetrics, _PerformanceRequestMiddleware


class CapturingSink:
    def __init__(self):
        self.records = []

    def submit(self, record):
        self.records.append(record)
        return True


def make_middleware(inner, sink):
    owner = FastAPI()
    owner.state.network_request_timeline = sink
    owner.router.routes.append(Route('/api/v1/profile/{identity}', endpoint=lambda request: None))
    return _PerformanceRequestMiddleware(inner, metrics=RequestLatencyMetrics(), owner_app=owner)


def scope(request_id=None):
    headers = [(b'x-trace-id', b'PRIVATE_AUDIT_ID'), (b'authorization', b'Bearer PRIVATE_TOKEN')]
    if request_id is not None:
        headers.append((b'x-chatflow-request-id', request_id.encode()))
    return {'type': 'http', 'method': 'GET', 'scheme': 'http', 'path': '/api/v1/profile/PRIVATE_ACCOUNT',
            'raw_path': b'/api/v1/profile/PRIVATE_ACCOUNT', 'query_string': b'token=PRIVATE_SECRET',
            'headers': headers, 'server': ('127.0.0.1', 8082), 'client': ('PRIVATE_IP', 1),
            'http_version': '1.1', 'route': Route('/api/v1/profile/{identity}', endpoint=lambda request: None)}


async def receive():
    return {'type': 'http.request', 'body': b'PRIVATE_BODY'}


@pytest.mark.asyncio
async def test_local_startup_route_never_accepts_caller_request_correlation():
    # This integration assertion applies to the locally implemented startup
    # route. The separately frozen production candidate has no such route.
    sink = CapturingSink()
    async def inner(request, receive, send):
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'', 'more_body': False})
    async def send(message):
        pass
    request = scope(str(uuid4()))
    request['path'] = '/api/v1/startup-diagnostics'
    await make_middleware(inner, sink)(request, receive, send)
    assert sink.records == []


@pytest.mark.asyncio
async def test_complete_after_real_final_send_and_no_sensitive_context(monkeypatch):
    sink = CapturingSink()
    request_id = str(uuid4())
    clock = [100.0]
    monkeypatch.setattr('app.core.tracing.perf_counter', lambda: clock[0])
    async def inner(request, receive, send):
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'PRIVATE_RESPONSE', 'more_body': True})
        await send({'type': 'http.response.body', 'body': b'', 'more_body': False})
        clock[0] += 1  # Post-response work is outside the request span.
        await asyncio.sleep(0)
    async def send(message):
        assert sink.records == []
        clock[0] += .003
        await asyncio.sleep(0)
    await make_middleware(inner, sink)(scope(request_id), receive, send)
    assert len(sink.records) == 1
    row = sink.records[0]
    assert row['event'] == 'server_request_timeline'
    assert row['request_id'] == request_id
    assert row['termination'] == 'complete' and row['http_status'] == 200
    assert row['headers_prepared_ms'] <= row['body_prepared_ms'] <= row['send_finished_ms'] == row['elapsed_ms']
    assert 8 <= row['elapsed_ms'] <= 10
    assert row['method'] == 'GET' and row['endpoint_category'] == 'profile'
    assert row['route_template'] == '/api/v1/profile/{identity}'
    assert 'PRIVATE_' not in json.dumps(row)


@pytest.mark.asyncio
@pytest.mark.parametrize('failure', [RuntimeError('PRIVATE_EXCEPTION'), asyncio.CancelledError('PRIVATE_EXCEPTION')])
@pytest.mark.parametrize('before_headers', [True, False])
async def test_exception_cancellation_do_not_fake_status_or_send_completion(failure, before_headers):
    sink = CapturingSink()
    async def inner(request, receive, send):
        if not before_headers:
            await send({'type': 'http.response.start', 'status': 201, 'headers': []})
            await send({'type': 'http.response.body', 'body': b'PRIVATE_RESPONSE', 'more_body': False})
        else:
            raise failure
    async def send(message):
        if message['type'] == 'http.response.body':
            raise failure
    with pytest.raises(type(failure)):
        await make_middleware(inner, sink)(scope(str(uuid4())), receive, send)
    row = sink.records[0]
    assert row['termination'] == ('cancelled' if isinstance(failure, asyncio.CancelledError) else 'exception')
    assert 'send_finished_ms' not in row
    assert ('http_status' in row) == (not before_headers)
    assert 'PRIVATE_' not in json.dumps(row)


@pytest.mark.asyncio
@pytest.mark.parametrize('request_id', [None, 'PRIVATE_REQUEST_ID', 'f'*36, str(uuid4()).replace('-', '')])
async def test_missing_or_invalid_header_preserves_legacy_no_timeline(request_id):
    sink = CapturingSink()
    async def inner(request, receive, send):
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'', 'more_body': False})
    async def send(message):pass
    await make_middleware(inner, sink)(scope(request_id), receive, send)
    assert sink.records == []


@pytest.mark.asyncio
@pytest.mark.parametrize('other_header', ['x-trace-id', 'x-chatflow-performance-id'])
async def test_request_correlation_cannot_reuse_audit_or_operation_id(other_header):
    sink = CapturingSink()
    request_id = str(uuid4())
    request = scope(request_id)
    request['headers'] = [(name, value) for name, value in request['headers'] if name.decode() != other_header]
    request['headers'].append((other_header.encode(), request_id.encode()))
    async def inner(request, receive, send):
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'', 'more_body': False})
    async def send(message):pass
    await make_middleware(inner, sink)(request, receive, send)
    assert sink.records == []


def sink_class():
    try:
        module = importlib.import_module('app.core.network_request_timeline')
    except ImportError:
        pytest.fail('Bounded nonblocking timeline sink is not implemented')
    return module.NetworkRequestTimelineSink


def record():
    return {'event': 'server_request_timeline', 'request_id': str(uuid4()),
            'server_started_at': '2026-09-27T05:05:00Z', 'elapsed_ms': 1,
            'method': 'GET', 'endpoint_category': 'profile', 'route_template': '/api/v1/profile/me',
            'termination': 'complete', 'http_status': 200,
            'headers_prepared_ms': 0, 'body_prepared_ms': 1, 'send_finished_ms': 1}


def test_blocked_writer_never_blocks_submit_and_drop_counts_are_fixed():
    entered, release = Event(), Event()
    output = []
    def writer(line):
        entered.set()
        release.wait(2)
        output.append(line)
    sink = sink_class()(capacity=1, rate_limit=20, writer=writer)
    try:
        assert sink.submit(record())
        assert entered.wait(1)
        assert sink.submit(record())
        started = time.monotonic()
        assert not sink.submit(record())
        assert time.monotonic() - started < .1
        assert sink.snapshot()['queue_full'] == 1
        assert sink.thread.daemon
    finally:
        release.set()
        sink.close(timeout=1)
    assert not sink.thread.is_alive()
    assert all('PRIVATE' not in item for item in output)
    assert any(json.loads(item)['event'] == 'server_request_timeline_dropped' for item in output)


def test_global_limit_closed_invalid_and_writer_error_remain_bounded():
    output = []
    sink = sink_class()(capacity=4, rate_limit=1, writer=output.append)
    try:
        assert sink.submit(record())
        assert not sink.submit(record())
        assert sink.snapshot()['rate_limited'] == 1
        assert not sink.submit({**record(), 'authorization': 'PRIVATE_SECRET'})
    finally:
        sink.close(timeout=1)
    assert not sink.submit(record())
    assert sink.snapshot()['closed'] == 1
    assert not sink.thread.is_alive()
    def failing_writer(line):raise RuntimeError('PRIVATE_EXCEPTION')
    broken = sink_class()(writer=failing_writer)
    broken.submit(record())
    broken.close(timeout=1)
    assert broken.snapshot()['sink_error'] >= 1
    assert not broken.thread.is_alive()


def test_lazy_sink_and_installed_app_shutdown_release_resources():
    from app.core.tracing import install_trace_middleware
    from fastapi.testclient import TestClient
    app = FastAPI()
    install_trace_middleware(app)
    sink = app.state.network_request_timeline
    assert sink.thread.ident is None
    @app.get('/api/v1/profile/me')
    def profile():return {'ok': True}
    with TestClient(app) as client:
        assert client.get('/api/v1/profile/me').status_code == 200
        assert sink.thread.ident is None
        assert client.get('/api/v1/profile/me', headers={'X-ChatFlow-Request-Id': str(uuid4())}).status_code == 200
        assert sink.thread.is_alive()
    assert not sink.thread.is_alive()


@pytest.mark.asyncio
async def test_registered_template_and_database_scope_fence_remain_separate():
    from app.core.tracing import capture_request_database_scope
    sink = CapturingSink()
    owner = FastAPI()
    engine = type('Engine', (), {'_chatflow_database_metrics': object()})()
    owner.state.engine = engine
    owner.state.network_request_timeline = sink
    owner.router.routes.append(Route('/api/v1/profile/me', endpoint=lambda request: None))
    checks = []
    async def inner(request, receive, send):
        checks.append(capture_request_database_scope(engine) is not None)
        assert request['state']['trace_id'] == 'PRIVATE_AUDIT_ID'
        await send({'type': 'http.response.start', 'status': 200, 'headers': []})
        await send({'type': 'http.response.body', 'body': b'', 'more_body': False})
        checks.append(capture_request_database_scope(engine) is None)
    async def send(message):pass
    request = scope(str(uuid4()))
    request['headers'].append((b'x-chatflow-performance-id', str(uuid4()).encode()))
    request['route'] = Route('/PRIVATE_ACCOUNT', endpoint=lambda request: None)
    middleware = _PerformanceRequestMiddleware(inner, metrics=RequestLatencyMetrics(), owner_app=owner)
    await middleware(request, receive, send)
    assert checks == [True, True]
    assert sink.records[0]['route_template'] == '<unmatched>'
    assert sink.records[0]['endpoint_category'] == 'other'
    assert 'PRIVATE_' not in json.dumps(sink.records)


def test_rate_window_reopens_and_caller_mutation_is_not_retained():
    release = Event()
    output = []
    clock = [100.0]
    def writer(line):
        release.wait(1)
        output.append(json.loads(line))
    sink = sink_class()(capacity=4, rate_limit=1, writer=writer, clock=lambda: clock[0])
    first = record()
    assert sink.submit(first)
    first['route_template'] = '/PRIVATE_ACCOUNT'
    assert not sink.submit(record())
    clock[0] += 60
    assert sink.submit(record())
    release.set()
    sink.close(timeout=1)
    assert not sink.thread.is_alive()
    assert 'PRIVATE_' not in json.dumps(output)


def test_daemon_has_no_caller_context_and_blocked_shutdown_is_bounded():
    private_context = ContextVar('private_request_context', default=None)
    private_context.set('PRIVATE_AUDIT_TOKEN')
    entered, release = Event(), Event()
    observed = []
    def writer(line):
        observed.append(private_context.get())
        entered.set()
        release.wait(2)
    sink = sink_class()(writer=writer)
    sink.submit(record())
    assert entered.wait(1)
    started = time.monotonic()
    sink.close(timeout=.01)
    assert time.monotonic() - started < .2
    assert sink.thread.daemon
    release.set()
    sink.close(timeout=1)
    assert not sink.thread.is_alive()
    assert observed and all(value is None for value in observed)


def test_drop_marker_is_boolean_true_and_no_arbitrary_fields():
    from app.core.network_request_timeline import NetworkRequestTimelineDrops
    from pydantic import ValidationError
    value = {'event': 'server_request_timeline_dropped', 'cumulative': 1,
             'queue_full': 0, 'rate_limited': 0, 'closed': 0, 'sink_error': 0}
    with pytest.raises(ValidationError):
        NetworkRequestTimelineDrops.model_validate(value)
    value['cumulative'] = True
    value['message'] = 'PRIVATE_TOKEN'
    with pytest.raises(ValidationError):
        NetworkRequestTimelineDrops.model_validate(value)
