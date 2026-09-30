import importlib.util
import shutil
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from uuid import uuid4

import pytest
from redis import Redis
from redis.exceptions import ConnectionError as RedisConnectionError


def test_dedicated_atomic_admission_exists():
    assert importlib.util.find_spec('app.core.startup_diagnostics_admission') is not None


@pytest.fixture(scope='module')
def redis_client():
    executable = shutil.which('redis-server')
    if executable is None:
        pytest.skip('local redis-server unavailable; real Redis integration requires it')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    artifacts = Path(__file__).resolve().parents[2] / 'docs/verification/artifacts/2026-09-27/ios-startup-alerts/backend'
    artifacts.mkdir(parents=True, exist_ok=True)
    with (artifacts / 'redis.log').open('w', encoding='utf-8') as output:
        process = subprocess.Popen([executable, '--bind', '127.0.0.1', '--port', str(port),
                                    '--save', '', '--appendonly', 'no', '--dir', str(artifacts)],
                                   stdout=output, stderr=subprocess.STDOUT,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        client = Redis(host='127.0.0.1', port=port, decode_responses=True,
                       socket_timeout=1, socket_connect_timeout=1)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    pytest.fail('isolated Redis exited; inspect backend/redis.log')
                try:
                    if client.ping():
                        break
                except RedisConnectionError:
                    pass
                time.sleep(.02)
            else:
                pytest.fail('isolated Redis failed startup')
            yield client
        finally:
            client.close()
            process.terminate()
            process.wait(timeout=5)


@pytest.fixture
def admission(redis_client):
    from app.core.startup_diagnostics_admission import RedisStartupDiagnosticsAdmission
    namespace = 'test:startup:' + str(uuid4())
    instance = RedisStartupDiagnosticsAdmission(redis_client, namespace=namespace)
    yield instance
    keys = list(redis_client.scan_iter(match=namespace + ':*'))
    if keys:
        redis_client.delete(*keys)


def test_source_limit_all_counters_have_atomic_ttl(admission, redis_client):
    for _ in range(10):
        assert admission.admit(str(uuid4()), '192.0.2.17')[0] == 'new'
    assert admission.admit(str(uuid4()), '192.0.2.17') == ('limited', None)
    keys = list(redis_client.scan_iter(match=admission.namespace + ':*'))
    assert len(keys) == 4
    assert all(redis_client.ttl(key) > 0 for key in keys)
    assert '192.0.2.17' not in ' '.join(keys)


def test_global_limit_runs_first_and_prevents_unbounded_source_keys(admission, redis_client):
    for index in range(120):
        assert admission.admit(str(uuid4()), str(index))[0] == 'new'
    for index in range(120, 200):
        assert admission.admit(str(uuid4()), str(index)) == ('limited', None)
    keys = list(redis_client.scan_iter(match=admission.namespace + ':source:*'))
    assert len(keys) == 120
    assert all(redis_client.ttl(key) > 0 for key in keys)


def test_concurrent_same_event_has_one_lease_and_completed_duplicate(admission):
    event_id = str(uuid4())
    with ThreadPoolExecutor(max_workers=20) as pool:
        outcomes = list(pool.map(lambda index: admission.admit(event_id, str(index)), range(20)))
    new = [token for result, token in outcomes if result == 'new']
    assert len(new) == 1
    assert sum(result == 'busy' for result, _ in outcomes) == 19
    assert admission.complete(event_id, new[0])
    assert admission.admit(event_id, 'next') == ('duplicate', None)


def test_release_and_expired_lease_can_retry_but_stale_owner_cannot_complete(admission, redis_client):
    event_id = str(uuid4())
    _, token = admission.admit(event_id, 'source')
    admission.release(event_id, 'wrong-owner')
    assert admission.admit(event_id, 'source') == ('busy', None)
    redis_client.hset(admission.namespace + ':states', event_id, 'p:0:' + token)
    _, next_token = admission.admit(event_id, 'source')
    assert next_token != token
    assert not admission.complete(event_id, token)
    admission.release(event_id, token)
    assert admission.admit(event_id, 'source') == ('busy', None)
    admission.release(event_id, next_token)
    assert admission.admit(event_id, 'source')[0] == 'new'


def test_capacity_is_fixed_cleanup_bounded_and_expired_events_reclaim_space(admission, redis_client):
    now = int(redis_client.time()[0])
    identifiers = [str(uuid4()) for _ in range(10000)]
    redis_client.zadd(admission.namespace + ':expiries', {event: now + 86400 for event in identifiers})
    redis_client.hset(admission.namespace + ':states', mapping={event: 'd' for event in identifiers})
    assert admission.admit(str(uuid4()), 'source') == ('limited', None)
    redis_client.zadd(admission.namespace + ':expiries', {event: 0 for event in identifiers[:200]})
    assert admission.admit(str(uuid4()), 'source')[0] == 'new'
    assert redis_client.zcard(admission.namespace + ':expiries') == 10000 - 128 + 1
    assert redis_client.hlen(admission.namespace + ':states') == 10000 - 128 + 1


def test_completed_event_expires_after_24h_and_no_dynamic_event_keys(admission, redis_client):
    event_id = str(uuid4())
    _, token = admission.admit(event_id, 'source')
    assert admission.complete(event_id, token)
    now = int(redis_client.time()[0])
    score = redis_client.zscore(admission.namespace + ':expiries', event_id)
    assert now + 86398 <= score <= now + 86401
    assert not any(event_id in key for key in redis_client.scan_iter(match=admission.namespace + ':*'))
    redis_client.zadd(admission.namespace + ':expiries', {event_id: 0})
    assert admission.admit(event_id, 'source')[0] == 'new'


def test_existing_missing_ttl_is_repaired_inside_atomic_script(admission, redis_client):
    redis_client.set(admission.namespace + ':global', 0)
    assert admission.admit(str(uuid4()), 'source')[0] == 'new'
    assert 0 < redis_client.ttl(admission.namespace + ':global') <= 60


def test_forwarded_headers_cannot_bypass_actual_source_limit(admission, capsys):
    from datetime import datetime, timezone
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.api.startup_diagnostics import create_startup_diagnostics_router
    from app.core.errors import install_error_handlers
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_startup_diagnostics_router(admission))
    client = TestClient(app)
    for index in range(11):
        data = {'schema': 1, 'platform': 'ios', 'event_id': str(uuid4()),
                'occurred_at': datetime.now(timezone.utc).replace(second=0, microsecond=0).isoformat(),
                'app_version': '0.4.15', 'build': 2185, 'os_version': 'unknown',
                'stage': 'initialization', 'boundary': 'version_load', 'category': 'unknown', 'count': 1}
        response = client.post('/startup-diagnostics', json=data,
                               headers={'X-Forwarded-For': f'192.0.2.{index}'})
        assert response.status_code == (202 if index < 10 else 429)
    output = capsys.readouterr().out
    assert len(output.splitlines()) == 10
    assert '192.0.2.' not in output


def test_malformed_requests_charge_global_first_and_create_only_bounded_ttl_source(admission, redis_client):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.api.startup_diagnostics import create_startup_diagnostics_router
    from app.core.errors import install_error_handlers
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_startup_diagnostics_router(admission))
    client = TestClient(app)
    for index in range(120):
        response = client.post('/startup-diagnostics', content=b'PRIVATE_SECRET',
                               headers={'X-Forwarded-For': f'192.0.2.{index}'})
        assert response.status_code == (422 if index < 10 else 429)
    assert int(redis_client.get(admission.namespace + ':global')) == 120
    keys = list(redis_client.scan_iter(match=admission.namespace + ':*'))
    assert len(keys) == 2 and all(redis_client.ttl(key) > 0 for key in keys)
    assert not admission.check_source('new-connection')
    assert len(list(redis_client.scan_iter(match=admission.namespace + ':*'))) == 2


def test_requested_expired_completed_uuid_outside_cleanup_batch_reserves_fresh_lease(admission, redis_client):
    now = int(redis_client.time()[0])
    target = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
    earlier = [f'00000000-0000-4000-8000-{index:012x}' for index in range(199)]
    expired = [*earlier, target]
    redis_client.zadd(admission.namespace + ':expiries', {event: now - 1 for event in expired})
    redis_client.hset(admission.namespace + ':states', mapping={event: 'd' for event in expired})
    result, token = admission.reserve(target)
    assert result == 'new' and token
    assert redis_client.zcard(admission.namespace + ':expiries') == 72
    assert redis_client.hlen(admission.namespace + ':states') == 72
    assert redis_client.zscore(admission.namespace + ':expiries', target) > now
    assert admission.complete(target, token)
    assert admission.reserve(target) == ('duplicate', None)


def test_completed_state_without_expiry_index_cannot_be_acknowledged_as_duplicate(admission, redis_client):
    target = str(uuid4())
    redis_client.hset(admission.namespace + ':states', target, 'd')
    result, token = admission.reserve(target)
    assert result == 'new' and token
    assert redis_client.zscore(admission.namespace + ':expiries', target) is not None
    assert redis_client.hget(admission.namespace + ':states', target).startswith('p:')
