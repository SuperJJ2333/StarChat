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


def frame_summary():
    return {'frame_count': 100, 'slow_frame_count': 7,
            'slow_build_count': 4, 'slow_raster_count': 5}


def test_frame_summary_without_error_events(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data.update(events=[], frames=frame_summary())
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 0}
    assert json.loads(capsys.readouterr().out)['frames'] == frame_summary()


@pytest.mark.parametrize('change', [
    {'frame_count': 0}, {'frame_count': 1000001}, {'frame_count': True},
    {'slow_frame_count': 101}, {'slow_frame_count': 4},
    {'slow_frame_count': 10}, {'slow_build_count': -1},
    {'slow_raster_count': '5'}, {'device_id': 'PRIVATE_CREDENTIAL'},
])
def test_frame_summary_rejects_invalid_counts_and_identifiers(endpoint, capsys, change):
    client, _, headers = endpoint
    data = payload()
    data['frames'] = {**frame_summary(), **change}
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_CREDENTIAL' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('stage', [
    'pending_write_failed', 'request_uncertain', 'result_write_failed',
    'retry_recovered', 'terminal_invalidated', 'result_superseded',
])
def test_refresh_diagnostics_closed_metadata(endpoint, capsys, stage):
    client, _, headers = endpoint
    data = payload()
    data['events'][0].update(stage=stage, error='recovered',
                             retry_count=1, lifecycle='foreground')
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    logged = json.loads(capsys.readouterr().out)
    assert logged['events'][0]['stage'] == stage
    assert logged['events'][0]['retry_count'] == 1
    assert headers['Authorization'] not in json.dumps(logged)


@pytest.mark.parametrize('extra', [
    {'refresh_token': 'PRIVATE_CREDENTIAL'},
    {'pending_refresh_operation': 'PRIVATE_CREDENTIAL'},
    {'retry_count': 21}, {'retry_count': -1}, {'retry_count': True},
    {'lifecycle': 'PRIVATE_CREDENTIAL'},
])
def test_refresh_diagnostics_reject_sensitive_or_unbounded_fields(endpoint, capsys, extra):
    client, _, headers = endpoint
    data = payload()
    data['events'][0].update(extra)
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_CREDENTIAL' not in response.text
    assert capsys.readouterr().out == ''


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


def performance_operation():
    return {
        'operation_id': str(uuid4()),
        'operation': 'conversation_open',
        'result': 'slow',
        'total_ms': 1830,
        'stages': [
            {'stage': 'user_action', 'elapsed_ms': 0},
            {'stage': 'first_frame_rendered', 'elapsed_ms': 80},
            {'stage': 'remote_sync_ready', 'elapsed_ms': 1830},
        ],
        'lifecycle': 'foreground',
        'slow_frame_count': 0,
        'slow_build_count': 0,
        'slow_raster_count': 0,
        'opening_source': 'local_room',
        'app_network_state': 'weak',
        'matrix_state': 'connecting',
        'transport_available': True,
        'service_reachable': True,
        'network_error': 'read_timeout',
        'endpoint_category': 'contacts',
        'method': 'get',
        'status_code': 200,
        'retry_count': 1,
        'cache_source': 'disk',
        'media_type': 'image',
        'size_bucket': 'small',
        'scheduler_queue': 2,
        'scheduler_active': 1,
        'rtt_ms': 220.0,
        'jitter_ms': 74.0,
        'packet_loss_percent': 8.2,
        'uses_turn': True,
        'relay_protocol': 'tcp',
        'candidate_protocol': 'udp',
    }


def performance_batch():
    return {'version': '0.4.9+2168', 'platform': 'android',
            'operations': [performance_operation()]}


def test_performance_operation_only_accepts_closed_metadata(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    logged = json.loads(capsys.readouterr().out)
    assert logged['operations'] == data['operations']
    assert 'private-user-sentinel' not in json.dumps(logged)
    assert headers['Authorization'] not in json.dumps(logged)


def test_search_page_open_operation_uses_the_closed_upload_schema(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['operation'] = 'search_page_open'
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    assert json.loads(capsys.readouterr().out)['operations'][0]['operation'] == 'search_page_open'


def test_recent_pictures_load_operation_keeps_gallery_metadata_private(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = data['operations'][0]
    operation['operation'] = 'recent_pictures_load'
    operation['stages'] = [
        {'stage': 'route_enter', 'elapsed_ms': 0},
        {'stage': 'first_frame_rendered', 'elapsed_ms': 50},
        {'stage': 'content_ready', 'elapsed_ms': 190},
    ]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['operation'] == 'recent_pictures_load'
    assert 'gallery_name' not in logged
    assert 'media_path' not in logged


def test_shared_media_flight_wait_has_closed_stages_without_queue_claim(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = data['operations'][0]
    operation['operation'] = 'media_load'
    operation['cache_source'] = 'unknown'
    operation['stages'] = [
        {'stage': 'cache_load_started', 'elapsed_ms': 0},
        {'stage': 'shared_flight_joined', 'elapsed_ms': 20},
        {'stage': 'shared_flight_done', 'elapsed_ms': 170},
        {'stage': 'cache_load_done', 'elapsed_ms': 170},
    ]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['cache_source'] == 'unknown'
    assert 'queue_entered' not in [mark['stage'] for mark in logged['stages']]


@pytest.mark.parametrize('priority', ['interactive', 'visible', 'prefetch', 'background'])
@pytest.mark.parametrize('video_active', [0, 1000])
def test_media_scheduler_accepts_real_priority_and_video_active_count(
        endpoint, capsys, priority, video_active):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0].update(
        operation='media_load', media_priority=priority,
        scheduler_video_active=video_active,
    )
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['media_priority'] == priority
    assert logged['scheduler_video_active'] == video_active


@pytest.mark.parametrize('field,value', [
    ('media_priority', 'normal'),
    ('media_priority', 'PRIVATE_CREDENTIAL'),
    ('scheduler_video_active', -1),
    ('scheduler_video_active', 1001),
    ('scheduler_video_active', True),
    ('scheduler_video_active', '1'),
])
def test_media_scheduler_rejects_unmeasured_or_private_metadata(
        endpoint, capsys, field, value):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0][field] = value
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_CREDENTIAL' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('cache_source', ['server_poster', 'local_frame'])
def test_real_poster_sources_use_closed_cache_values(endpoint, capsys, cache_source):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['operation'] = 'video_poster'
    data['operations'][0]['cache_source'] = cache_source
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert json.loads(capsys.readouterr().out)['operations'][0]['cache_source'] == cache_source


@pytest.mark.parametrize('field,value', [
    ('operation', 'conversation_refresh'),
    ('operation', 'media_upload'),
    ('operation', 'image_decode'),
    ('operation', 'avatar_load'),
    ('operation', 'call_reconnect'),
    ('opening_source', 'remote_resolved'),
])
def test_removed_unobserved_wire_values_are_rejected(endpoint, capsys, field, value):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0][field] = value
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert capsys.readouterr().out == ''


def test_room_attach_start_and_done_stages_share_one_operation(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['stages'] = [
        {'stage': 'user_action', 'elapsed_ms': 0},
        {'stage': 'room_attach_started', 'elapsed_ms': 50},
        {'stage': 'room_attach_done', 'elapsed_ms': 70},
    ]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    assert json.loads(capsys.readouterr().out)['operations'][0]['stages'] == data['operations'][0]['stages']


def test_local_timeline_start_and_ready_stages_are_accepted(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['stages'] = [
        {'stage': 'user_action', 'elapsed_ms': 0},
        {'stage': 'timeline_local_started', 'elapsed_ms': 40},
        {'stage': 'local_timeline_ready', 'elapsed_ms': 90},
    ]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    assert json.loads(capsys.readouterr().out)['operations'][0]['stages'] == data['operations'][0]['stages']


def test_conversation_open_accepts_measured_sync_wait_start(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['stages'] = [
        {'stage': 'user_action', 'elapsed_ms': 0},
        {'stage': 'local_timeline_ready', 'elapsed_ms': 90},
        {'stage': 'sync_response_wait_started', 'elapsed_ms': 120},
        {'stage': 'sync_response_received', 'elapsed_ms': 280},
        {'stage': 'remote_sync_ready', 'elapsed_ms': 350},
    ]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 1}
    assert json.loads(capsys.readouterr().out)['operations'][0]['stages'] == data['operations'][0]['stages']


def test_app_resume_accepts_measured_stages_and_watchdog_counters(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = data['operations'][0]
    operation.update(
        operation='app_resume',
        stages=[
            {'stage': 'user_action', 'elapsed_ms': 0},
            {'stage': 'matrix_connected', 'elapsed_ms': 500},
            {'stage': 'sync_finished', 'elapsed_ms': 600},
            {'stage': 'conversation_ready', 'elapsed_ms': 800},
        ],
        soft_kick_count=2,
        hard_restart_count=1,
        sync_error_count=3,
        reconnect_count=4,
        last_healthy_sync_age_ms=1700,
    )
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['stages'] == operation['stages']
    assert logged['soft_kick_count'] == 2
    assert logged['hard_restart_count'] == 1
    assert logged['sync_error_count'] == 3
    assert logged['reconnect_count'] == 4
    assert logged['last_healthy_sync_age_ms'] == 1700


@pytest.mark.parametrize('value,age_ms', [(0, 0), (1000, 3600000)])
def test_app_resume_accepts_sync_counter_boundaries(endpoint, capsys, value, age_ms):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0].update(
        operation='app_resume',
        sync_error_count=value,
        reconnect_count=value,
        last_healthy_sync_age_ms=age_ms,
    )
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['sync_error_count'] == value
    assert logged['reconnect_count'] == value
    assert logged['last_healthy_sync_age_ms'] == age_ms


def test_performance_accepts_closed_database_and_search_count_metadata(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = data['operations'][0]
    operation.update(database_operation='message_search',
                     row_count_bucket='twenty_one_to_hundred',
                     result_count_bucket='one_to_twenty')
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    logged = json.loads(capsys.readouterr().out)['operations'][0]
    assert logged['database_operation'] == 'message_search'
    assert logged['row_count_bucket'] == 'twenty_one_to_hundred'
    assert logged['result_count_bucket'] == 'one_to_twenty'


@pytest.mark.parametrize('field', [
    'database_operation', 'row_count_bucket', 'result_count_bucket',
])
def test_performance_rejects_arbitrary_database_metadata(endpoint, capsys, field):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0][field] = 'PRIVATE_CREDENTIAL'
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'PRIVATE_CREDENTIAL' not in response.text
    assert capsys.readouterr().out == ''


@pytest.mark.parametrize('key,bad', [
    ('soft_kick_count', -1), ('soft_kick_count', True),
    ('soft_kick_count', 1001), ('soft_kick_count', '1'),
    ('hard_restart_count', -1), ('hard_restart_count', True),
    ('hard_restart_count', 1001), ('hard_restart_count', '1'),
    ('sync_error_count', -1), ('sync_error_count', True),
    ('sync_error_count', 1001), ('sync_error_count', '1'),
    ('reconnect_count', -1), ('reconnect_count', True),
    ('reconnect_count', 1001), ('reconnect_count', '1'),
    ('last_healthy_sync_age_ms', -1), ('last_healthy_sync_age_ms', True),
    ('last_healthy_sync_age_ms', 3600001), ('last_healthy_sync_age_ms', '1'),
])
def test_app_resume_rejects_invalid_watchdog_counters(endpoint, capsys, key, bad):
    client, _, headers = endpoint
    data = performance_batch()
    data['operations'][0]['operation'] = 'app_resume'
    data['operations'][0][key] = bad
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert capsys.readouterr().out == ''


def test_performance_and_legacy_events_share_receipt_count(endpoint, capsys):
    client, _, headers = endpoint
    data = payload()
    data['operations'] = [performance_operation()]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 2}
    logged = json.loads(capsys.readouterr().out)
    assert len(logged['events']) == 1
    assert len(logged['operations']) == 1


@pytest.mark.parametrize('mutate', [
    lambda op: op.update(room_id='!private:matrix'),
    lambda op: op.update(user_id='private-user'),
    lambda op: op.update(message='private-message'),
    lambda op: op.update(access_token='private-token'),
    lambda op: op.update(url='https://example.test?token=private-token'),
    lambda op: op.update(sql='SELECT private_message'),
    lambda op: op.update(operation='private-operation'),
    lambda op: op.update(result='private-result'),
    lambda op: op.update(lifecycle='private-lifecycle'),
    lambda op: op.update(opening_source='private-source'),
    lambda op: op.update(app_network_state='private-state'),
    lambda op: op.update(matrix_state='private-state'),
    lambda op: op.update(network_error='private-error'),
    lambda op: op.update(endpoint_category='private-category'),
    lambda op: op.update(method='private-method'),
    lambda op: op.update(cache_source='private-cache'),
    lambda op: op.update(media_type='private-type'),
    lambda op: op.update(size_bucket='private-size'),
    lambda op: op.update(relay_protocol='private-protocol'),
    lambda op: op.update(candidate_protocol='private-protocol'),
    lambda op: op.update(operation_id='private-id'),
    lambda op: op.update(total_ms=-1),
    lambda op: op.update(total_ms=True),
    lambda op: op.update(total_ms=3600001),
    lambda op: op.update(status_code=600),
    lambda op: op.update(retry_count=21),
    lambda op: op.update(scheduler_queue=1001),
    lambda op: op.update(scheduler_active=-1),
    lambda op: op.update(rtt_ms=-1),
    lambda op: op.update(jitter_ms=60001),
    lambda op: op.update(packet_loss_percent=101),
    lambda op: op.update(uses_turn='true'),
    lambda op: op.update(transport_available='true'),
    lambda op: op.update(service_reachable='true'),
    lambda op: op.update(slow_frame_count=2),
    lambda op: op.update(slow_build_count=-1),
    lambda op: op.update(slow_raster_count=True),
    lambda op: op['stages'][0].update(stage='private-stage'),
    lambda op: op['stages'][0].update(elapsed_ms='0'),
    lambda op: op['stages'][0].update(payload='private-message'),
    lambda op: op['stages'].append({'stage': 'user_action', 'elapsed_ms': 100}),
    lambda op: op['stages'].append({'stage': 'content_ready', 'elapsed_ms': 2000}),
    lambda op: op['stages'].insert(1, {'stage': 'content_ready', 'elapsed_ms': 200}),
    lambda op: op.update(stages=[{'stage': 'user_action', 'elapsed_ms': 0}] * 65),
])
def test_performance_operation_rejects_private_or_inconsistent_fields(
        endpoint, capsys, mutate):
    client, _, headers = endpoint
    data = performance_batch()
    mutate(data['operations'][0])
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert 'private-' not in response.text
    assert capsys.readouterr().out == ''


def test_performance_batch_max_twenty(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = performance_operation()
    required = ('operation', 'result', 'total_ms', 'stages', 'lifecycle',
                'slow_frame_count', 'slow_build_count', 'slow_raster_count')
    small = {key: operation[key] for key in required}
    data['operations'] = [{**small, 'operation_id': str(uuid4())} for _ in range(21)]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 422
    assert capsys.readouterr().out == ''


def test_dart_performance_enum_wire_names_match_server_allowlists():
    import re
    from pathlib import Path
    from typing import get_args

    from app.api import client_diagnostics as schema

    dart = (Path(__file__).parents[2] / 'apps/mobile_flutter/lib/core/'
            'performance_trace_model.dart').read_text(encoding='utf-8')
    enum_bodies = dict(re.findall(r'enum (Performance\w+)\s*\{([^}]+)\}', dart, re.S))
    pairs = {
        'PerformanceOperationType': 'OperationWire',
        'PerformanceStage': 'PerformanceStageWire',
        'PerformanceResult': 'PerformanceResultWire',
        'PerformanceOpeningSource': 'OpeningSourceWire',
        'PerformanceLifecycle': 'PerformanceLifecycleWire',
        'PerformanceAppNetworkState': 'AppNetworkStateWire',
        'PerformanceMatrixState': 'MatrixStateWire',
        'PerformanceNetworkError': 'NetworkErrorWire',
        'PerformanceEndpointCategory': 'EndpointCategoryWire',
        'PerformanceHttpMethod': 'HttpMethodWire',
        'PerformanceCacheSource': 'CacheSourceWire',
        'PerformanceMediaType': 'MediaTypeWire',
        'PerformanceSizeBucket': 'SizeBucketWire',
        'PerformanceDatabaseOperation': 'DatabaseOperationWire',
        'PerformanceRowCountBucket': 'RowCountBucketWire',
        'PerformanceRelayProtocol': 'RelayProtocolWire',
    }
    for dart_name, server_alias in pairs.items():
        expected = {
            re.sub(r'[A-Z]', lambda match: '_' + match.group().lower(), name.strip())
            for name in enum_bodies[dart_name].split(',') if name.strip()
        }
        assert set(get_args(getattr(schema, server_alias))) == expected


def test_performance_accepts_zero_numeric_boundaries(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = data['operations'][0]
    operation['rtt_ms'] = 0
    operation['jitter_ms'] = 0
    operation['packet_loss_percent'] = 0
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert json.loads(capsys.readouterr().out)['operations'][0]['rtt_ms'] == 0


def test_performance_accepts_twenty_small_records(endpoint, capsys):
    client, _, headers = endpoint
    data = performance_batch()
    operation = performance_operation()
    required = ('operation', 'result', 'total_ms', 'stages', 'lifecycle',
                'slow_frame_count', 'slow_build_count', 'slow_raster_count')
    small = {key: operation[key] for key in required}
    data['operations'] = [{**small, 'operation_id': str(uuid4())} for _ in range(20)]
    response = client.post('/api/v1/client-diagnostics', json=data, headers=headers)
    assert response.status_code == 202
    assert response.json() == {'accepted': 20}
    assert len(json.loads(capsys.readouterr().out)['operations']) == 20
