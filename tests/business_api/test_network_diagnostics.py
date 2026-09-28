"""Network summaries keep denominators, historical identity and closed metadata."""
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
    settings = Settings(environment='test', jwt_secret='test-secret-for-diagnostics-32-bytes')
    limiter = Limiter()
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_client_diagnostics_router(settings, None, limiter), prefix='/api/v1')
    now = int(time.time())
    token = jwt.encode({'sub': 'private-user-sentinel', 'iat': now, 'exp': now + 60,
                        'iss': settings.jwt_issuer}, settings.jwt_secret, algorithm='HS256')
    return TestClient(app), limiter, {'Authorization': f'Bearer {token}'}


def network_summary():
    return {'sample_id': str(uuid4()), 'version': '0.4.6+2165', 'platform': 'android',
            'window_start': '2026-09-25T18:00:00.000Z',
            'window_end': '2026-09-25T18:01:00.000Z',
            'target': 'primary_api', 'network': 'wifi', 'attempts': 8,
            'http_2xx': 2, 'http_3xx': 1, 'http_4xx': 1, 'http_5xx': 1,
            'network_errors': 1, 'timeouts': 1, 'cancelled': 1,
            'success_latency_buckets': [1, 0, 0, 0, 0, 0, 0, 0, 1]}


def payload():
    return {'version': '0.4.14+2181', 'platform': 'ios', 'events': [],
            'networks': [network_summary()]}


def test_network_only_accepts_and_logs_original_version_and_time(endpoint, capsys):
    client, limiter, headers = endpoint
    data = payload()
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 0}
    output = capsys.readouterr().out
    logged = json.loads(output)
    assert re.fullmatch(r'[0-9a-f]{64}', logged.pop('subject_ref'))
    assert logged == {'event': 'client_diagnostics', **data}
    assert 'private-user-sentinel' not in output
    assert headers['Authorization'] not in output
    assert [(limit, seconds) for _, limit, seconds in limiter.calls] == [(1, 60), (30, 60)]


@pytest.mark.parametrize('network', ['unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other'])
def test_all_closed_network_types_and_equal_utc_window_are_valid(endpoint, capsys, network):
    client, _, headers = endpoint
    data = payload()
    data['networks'][0].update(network=network, window_end='2026-09-25T18:00:00.000+00:00')
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    assert json.loads(capsys.readouterr().out)['networks'][0] == data['networks'][0]


@pytest.mark.parametrize('change', [
    {'sample_id': 'PRIVATE_SENTINEL'}, {'sample_id': str(uuid4()).replace('-', '')},
    {'version': 'PRIVATE_SENTINEL'}, {'version': '0.4.6-beta'}, {'platform': 'windows'},
    {'target': 'https://PRIVATE_SENTINEL'}, {'network': 'PRIVATE_SENTINEL'},
    {'attempts': 0}, {'attempts': 1000001}, {'attempts': True}, {'attempts': '8'},
    {'http_2xx': True}, {'http_3xx': -1}, {'http_4xx': 1000001},
    {'http_5xx': '1'}, {'network_errors': 0}, {'timeouts': True}, {'cancelled': 2},
    {'success_latency_buckets': [1] * 8}, {'success_latency_buckets': [1] * 10},
    {'success_latency_buckets': [False] + [0] * 7 + [2]},
    {'success_latency_buckets': [-1] + [0] * 7 + [3]},
    {'success_latency_buckets': ['1'] + [0] * 7 + [1]},
    {'success_latency_buckets': [1000001] + [0] * 8},
    {'success_latency_buckets': [0] * 9},
    {'window_start': 'PRIVATE_SENTINEL'}, {'window_start': '2026-02-30T18:00:00Z'},
    {'window_start': '2026-09-25T18:00:00'}, {'window_start': '2026-09-25T18:00:00+08:00'},
    {'window_start': '2026-09-25T18:02:00Z'}, {'window_end': '2026-09-25'},
    {'window_start': True}, {'window_end': 123},
    {'ip': 'PRIVATE_SENTINEL'}, {'carrier': 'PRIVATE_SENTINEL'},
])
def test_invalid_summary_rejected_without_logging_or_echo(endpoint, capsys, change):
    client, _, headers = endpoint
    data = payload()
    data['networks'][0].update(change)
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_SENTINEL' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('field', list(network_summary()))
def test_every_summary_field_is_required(endpoint, capsys, field):
    client, _, headers = endpoint
    data = payload()
    del data['networks'][0][field]
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    assert capsys.readouterr().out == ''


def test_maximum_eight_networks_and_outcome_count_boundary(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data['networks'] = [network_summary() for _ in range(8)]
    summary = data['networks'][0]
    summary.update(attempts=1000000, http_2xx=1000000, http_3xx=0, http_4xx=0,
                   http_5xx=0, network_errors=0, timeouts=0, cancelled=0,
                   success_latency_buckets=[1000000] + [0] * 8)
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    capsys.readouterr()
    data['networks'].append(network_summary())
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('conflict', [False, True])
def test_same_batch_duplicate_sample_ids_rejected(endpoint, capsys, conflict):
    client, _, headers = endpoint
    data = payload()
    duplicate = copy.deepcopy(data['networks'][0])
    if conflict:
        duplicate['network'] = 'mobile'
    data['networks'].append(duplicate)
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    assert capsys.readouterr().out == ''


def test_events_frames_and_networks_coexist_without_changing_receipt(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data.update(events=[{'operation_id': str(uuid4()), 'stage': 'matrixSend',
                        'error': 'timeout', 'elapsed_ms': 5000, 'count': 1}],
                frames={'frame_count': 10, 'slow_frame_count': 2,
                        'slow_build_count': 1, 'slow_raster_count': 1})
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    logged = json.loads(capsys.readouterr().out)
    assert re.fullmatch(r'[0-9a-f]{64}', logged.pop('subject_ref'))
    assert logged == {'event': 'client_diagnostics', **data}


def test_zero_success_all_failure_window_is_valid(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data['networks'][0].update(attempts=6, http_2xx=0, success_latency_buckets=[0] * 9)
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 202
    capsys.readouterr()


@pytest.mark.parametrize('networks', [[], None, True, 'PRIVATE_SENTINEL'])
def test_network_extension_does_not_allow_empty_batch(endpoint, capsys, networks):
    client, _, headers = endpoint
    data = payload()
    data['networks'] = networks
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 422
    assert capsys.readouterr().out == ''


def test_auth_limit_and_stream_bound_still_apply_to_networks(endpoint, capsys):
    client, limiter, headers = endpoint
    data = payload()
    assert client.post('/api/v1/client-diagnostics', json=data).status_code == 401
    assert client.post('/api/v1/client-diagnostics', content=b' ' * 17000,
                       headers=headers).status_code == 413
    limiter.block = True
    assert client.post('/api/v1/client-diagnostics', json=data, headers=headers).status_code == 429
    assert capsys.readouterr().out == ''
