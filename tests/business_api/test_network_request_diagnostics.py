"""Request failure metadata is closed, bounded and backwards compatible."""
import copy
import json
import re
import time
from uuid import uuid4

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api.client_diagnostics import create_client_diagnostics_router
from app.core.config import Settings
from app.core.errors import AppError, install_error_handlers


class Limiter:
    def __init__(self):
        self.calls = []
        self.block = False

    def hit(self, key, *, limit, window_seconds):
        self.calls.append((key, limit, window_seconds))
        if self.block:
            raise AppError(code='RATE_LIMITED', message='limited', status_code=429)


@pytest.fixture
def endpoint():
    settings = Settings(environment='test', jwt_secret='diagnostic-test-secret-at-least-32-bytes')
    limiter = Limiter()
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_client_diagnostics_router(settings, None, limiter), prefix='/api/v1')
    now = int(time.time())
    token = jwt.encode({'sub': 'PRIVATE_ACCOUNT', 'iat': now, 'exp': now + 60,
                       'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    return TestClient(app), limiter, {'Authorization': 'Bearer ' + token}


def request_record():
    return {'request_id': str(uuid4()), 'version': '0.4.17+2186', 'platform': 'android',
            'target': 'primary_api', 'network': 'wifi', 'method': 'GET',
            'endpoint_category': 'profile', 'started_at': '2026-09-27T05:05:00.000Z',
            'elapsed_ms': 8005, 'phase': 'awaiting_headers', 'reason': 'timeout',
            'timeout_budget_ms': 8000, 'timeout_lateness_ms': 5}


def payload():
    return {'version': '0.4.17+2186', 'platform': 'android', 'network_requests': [request_record()]}


def test_failure_only_is_accepted_without_sensitive_context(endpoint, capsys):
    client, limiter, headers = endpoint
    data = payload()
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    out = capsys.readouterr().out
    logged = json.loads(out)
    assert re.fullmatch(r'[0-9a-f]{64}', logged.pop('subject_ref'))
    assert logged == {'event': 'client_diagnostics', **data}
    assert 'PRIVATE_ACCOUNT' not in out and headers['Authorization'] not in out
    assert [(limit, seconds) for _, limit, seconds in limiter.calls] == [(1, 60), (30, 60)]


@pytest.mark.parametrize('change', [
    {'request_id': 'PRIVATE_SECRET'}, {'request_id': str(uuid4()).replace('-', '')},
    {'operation_id': 'PRIVATE_SECRET'}, {'version': 'PRIVATE_SECRET'},
    {'platform': 'PRIVATE_SECRET'}, {'network': 'PRIVATE_SECRET'},
    {'target': 'https://PRIVATE_SECRET'}, {'method': 'PRIVATE_SECRET'},
    {'endpoint_category': 'PRIVATE_SECRET'}, {'phase': 'dns'}, {'reason': 'PRIVATE_SECRET'},
    {'started_at': '2026-02-30T00:00:00Z'}, {'started_at': '2026-09-27T00:00:00+08:00'},
    {'elapsed_ms': True}, {'elapsed_ms': 3600001}, {'elapsed_ms': -1},
    {'headers_ms': 8006}, {'headers_ms': True}, {'http_status': 99}, {'http_status': '500'},
    {'timeout_budget_ms': 0}, {'timeout_budget_ms': 3600001}, {'timeout_lateness_ms': -1},
    {'reason': 'socket', 'timeout_budget_ms': 8000},
    {'reason': 'http_5xx', 'http_status': 200},
    {'phase': 'awaiting_headers', 'headers_ms': 1},
    {'phase': 'awaiting_headers', 'http_status': 500},
    {'phase': 'reading_body'}, {'phase': 'response_complete'},
    {'url': 'PRIVATE_SECRET'}, {'exception': 'PRIVATE_SECRET'}, {'account_id': 'PRIVATE_SECRET'},
])
def test_invalid_request_record_is_never_logged_or_echoed(endpoint, capsys, change):
    client, _, headers = endpoint
    data = payload()
    data['network_requests'][0].update(change)
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_SECRET' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('field', ['request_id', 'version', 'platform', 'target', 'network',
                                  'method', 'endpoint_category', 'started_at', 'elapsed_ms', 'phase', 'reason'])
def test_required_request_fields(endpoint, capsys, field):
    client, _, headers = endpoint
    data = payload()
    del data['network_requests'][0][field]
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('phase', ['reading_body', 'response_complete', 'unknown'])
def test_header_body_and_unknown_boundaries(endpoint, capsys, phase):
    client, _, headers = endpoint
    data = payload()
    row = data['network_requests'][0]
    row.update(phase=phase, headers_ms=3, http_status=503)
    row.pop('timeout_budget_ms')
    row.pop('timeout_lateness_ms')
    row['reason'] = 'http_5xx' if phase == 'response_complete' else 'http_transport'
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    assert json.loads(capsys.readouterr().out)['network_requests'][0] == row


def test_request_budget_duplicates_and_legacy_compatibility(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data['network_requests'] = [request_record() for _ in range(8)]
    data['events'] = [{'operation_id': str(uuid4()), 'stage': 'network_request',
                       'error': 'timeout', 'elapsed_ms': 8000, 'count': 1} for _ in range(12)]
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    capsys.readouterr()
    data['events'].append(copy.deepcopy(data['events'][0]))
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    capsys.readouterr()
    data = payload()
    data['network_requests'].append(copy.deepcopy(data['network_requests'][0]))
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    capsys.readouterr()
    data['network_requests'] = [request_record() for _ in range(9)]
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    capsys.readouterr()
    legacy = {'version': '0.4.15+2184', 'platform': 'android', 'events': [
        {'operation_id': str(uuid4()), 'stage': 'network_request', 'error': 'timeout', 'elapsed_ms': 8000, 'count': 1}]}
    assert client.post('/api/v1/client-diagnostics', json=legacy, headers=headers).status_code == 202
    logged = json.loads(capsys.readouterr().out)
    assert re.fullmatch(r'[0-9a-f]{64}', logged.pop('subject_ref'))
    assert logged == {'event': 'client_diagnostics', **legacy}


def test_existing_auth_stream_bound_and_rate_limits_are_preserved(endpoint, capsys):
    client, limiter, headers = endpoint
    assert client.post('/api/v1/client-diagnostics', json=payload()).status_code == 401
    assert client.post('/api/v1/client-diagnostics', content=b' '*16385, headers=headers).status_code == 413
    limiter.block = True
    assert client.post('/api/v1/client-diagnostics', json=payload(), headers=headers).status_code == 429
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('segment,expected', [
    ('phone', 'auth'), ('email', 'auth'), ('push', 'settings'), ('presence', 'settings'),
    ('groups', 'contacts'), ('moments', 'media'), ('app-update', 'settings'),
])
def test_fixed_endpoint_categories_match_client_golden(segment, expected):
    from app.core.network_request_timeline import endpoint_category_for_route
    assert endpoint_category_for_route('/api/v1/'+segment+'/{value}') == expected
