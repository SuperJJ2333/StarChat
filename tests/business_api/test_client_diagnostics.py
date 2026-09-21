import json
import time
from uuid import uuid4

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.requests import Request

from app.api.client_diagnostics import create_client_diagnostics_router, read_bounded_body
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
    settings = Settings(environment='test', jwt_secret='test-secret-for-diagnostics-32-bytes')
    limiter = Limiter()
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_client_diagnostics_router(settings, None, limiter), prefix='/api/v1')
    now = int(time.time())
    token = jwt.encode({'sub': 'private-user-sentinel', 'iat': now, 'exp': now + 60,
                        'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    return TestClient(app), limiter, {'Authorization': f'Bearer {token}'}


def payload():
    return {'version': '0.3.103+2153', 'platform': 'ios', 'events': [
        {'operation_id': str(uuid4()), 'stage': 'dateMonth', 'error': 'timeout',
         'elapsed_ms': 5000, 'count': 1, 'status': None}]}


def test_authenticated_safe_log_and_two_independent_limits(endpoint, capsys):
    client, limiter, headers = endpoint
    data = payload()
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    output = capsys.readouterr().out
    logged = json.loads(output)
    assert logged['events'] == data['events']
    assert 'private-user-sentinel' not in output
    assert headers['Authorization'] not in output
    assert len(limiter.calls) == 2
    assert all('private-user-sentinel' not in item[0] for item in limiter.calls)


def test_auth_and_rate_limit(endpoint, capsys):
    client, limiter, headers = endpoint
    assert client.post('/api/v1/client-diagnostics', json=payload()).status_code == 401
    assert client.post('/api/v1/client-diagnostics', json=payload(), headers={'Authorization': 'Bearer invalid'}).status_code == 401
    limiter.block = True
    assert client.post('/api/v1/client-diagnostics', json=payload(), headers=headers).status_code == 429
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('mutate', [
    lambda p: p.update(secret='CHAT_SECRET'),
    lambda p: p['events'][0].update(stack='CHAT_SECRET'),
    lambda p: p['events'][0].update(stage='CHAT_SECRET'),
    lambda p: p['events'][0].update(error='CHAT_SECRET'),
    lambda p: p.update(version='CHAT_SECRET'),
    lambda p: p.update(platform='CHAT_SECRET'),
    lambda p: p['events'][0].update(operation_id='CHAT_SECRET'),
    lambda p: p['events'][0].update(elapsed_ms='5000'),
    lambda p: p['events'][0].update(elapsed_ms=-1),
    lambda p: p['events'][0].update(elapsed_ms=3600001),
    lambda p: p['events'][0].update(count=0),
    lambda p: p['events'][0].update(count=1000001),
    lambda p: p['events'][0].update(count=True),
    lambda p: p['events'][0].update(status=999),
    lambda p: p.update(events=p['events'] * 21),
    lambda p: p.update(events=[]),
])
def test_closed_schema_no_sensitive_echo(endpoint, capsys, mutate):
    client, _, headers = endpoint
    data = payload()
    mutate(data)
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'CHAT_SECRET' not in response.text
    assert capsys.readouterr().out == ''


def test_body_size_checked_without_trusting_content_length(endpoint, capsys):
    client, _, headers = endpoint
    response = client.post('/api/v1/client-diagnostics', content=b' ' * 17000, headers=headers)
    assert response.status_code == 413
    assert capsys.readouterr().out == ''


@pytest.mark.asyncio
async def test_stream_stops_at_bound_without_reading_rest():
    chunks = iter([b'a' * 10000, b'b' * 7000, b'NEVER_READ'])
    consumed = 0

    async def receive():
        nonlocal consumed
        consumed += 1
        return {'type': 'http.request', 'body': next(chunks), 'more_body': True}

    request = Request({'type': 'http', 'headers': []}, receive)
    with pytest.raises(AppError) as error:
        await read_bounded_body(request)
    assert error.value.status_code == 413
    assert consumed == 2


def test_real_account_window_blocks_second_batch_and_does_not_log(endpoint, capsys):
    client, limiter, headers = endpoint
    seen = {}

    def hit(key, *, limit, window_seconds):
        assert window_seconds == 60
        seen[key] = seen.get(key, 0) + 1
        if seen[key] > limit:
            raise AppError(code='RATE_LIMITED', message='limited', status_code=429)

    limiter.hit = hit
    assert client.post('/api/v1/client-diagnostics', json=payload(), headers=headers).status_code == 202
    capsys.readouterr()
    assert client.post('/api/v1/client-diagnostics', json=payload(), headers=headers).status_code == 429
    assert capsys.readouterr().out == ''


def test_invalid_json_never_echoes_input(endpoint, capsys):
    client, _, headers = endpoint
    response = client.post('/api/v1/client-diagnostics', content=b'PRIVATE_SECRET not json', headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_SECRET' not in response.text
    assert capsys.readouterr().out == ''
