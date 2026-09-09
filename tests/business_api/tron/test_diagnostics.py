import io
import json
import logging

import httpx
import pytest
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

from app.integrations.tron import diagnostics as d
from app.integrations.tron.reader import TronReader, TronReadError
from app.integrations.tron.observer import Observer


@pytest.fixture
def logs():
    stream = io.StringIO()
    d.configure('test', level='DEBUG', stream=stream)
    yield stream
    d.configure('test', level='INFO', stream=io.StringIO())


def records(stream):
    return [json.loads(line) for line in stream.getvalue().splitlines()]


def test_configuration_restores_logger_disabled_by_migration_fileconfig(logs):
    logger = logging.getLogger('wallet.diagnostics')
    logger.disabled = True
    d.configure('test', stream=logs)
    d.emit('ERROR', 'request_failed', component='reader', reason_code='READ_TIMEOUT')
    assert records(logs)[-1]['reason_code'] == 'READ_TIMEOUT'


@pytest.mark.parametrize('failure,reason,status', [
    (429, 'HTTP_RATE_LIMITED', 429), (503, 'HTTP_SERVER_ERROR', 503),
    (401, 'HTTP_CLIENT_ERROR', 401), ('json', 'INVALID_JSON', 200),
    ('timeout', 'READ_TIMEOUT', None), ('connect', 'CONNECT_ERROR', None),
])
def test_request_failure_is_classified_and_redacted(logs, failure, reason, status):
    secret = 'DO_NOT_LOG_PASSWORD_OR_ADDRESS'
    def respond(request):
        if failure == 'timeout':
            raise httpx.ReadTimeout(secret, request=request)
        if failure == 'connect':
            raise httpx.ConnectError(secret, request=request)
        return httpx.Response(200 if failure == 'json' else failure, text=secret)
    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        reader = TronReader(client=client, api_key=secret)
        with d.span('observer'), pytest.raises(TronReadError, match='TRON request failed'):
            reader._request('GET', f'/v1/accounts/{secret}/transactions/trc20', params={'secret': secret})
    events = records(logs)
    failed = next(e for e in events if e['event'] == 'request_failed')
    assert failed['reason_code'] == reason
    assert failed.get('http_status') == status
    assert failed['stage'] == 'history'
    assert failed['route'] == '/v1/accounts/{address}/transactions/trc20'
    assert failed['trace_id'] and failed['request_id']
    assert secret not in logs.getvalue()
    assert failed['duration_ms'] >= 0


def test_levels_whitelist_context_and_sink_failure(logs):
    with d.span('observer'):
        d.emit('INFO', 'scan_completed', component='observer', password='secret', checkpoint_ms=123)
    with d.span('observer'):
        d.emit('DEBUG', 'request_started', component='reader')
    events = records(logs)
    assert events[0]['trace_id'] != events[1]['trace_id']
    assert 'password' not in events[0]
    assert events[0]['checkpoint_ms'] == 123
    quiet = io.StringIO()
    d.configure('test', level='INFO', stream=quiet)
    d.emit('DEBUG', 'request_started', component='reader')
    assert not quiet.getvalue()
    with pytest.raises(ValueError):
        d.configure('test', level='DEBUGGER')
    class Broken:
        def write(self, value):
            raise OSError('sensitive filesystem path')
        def flush(self):
            pass
    d.configure('test', stream=Broken())
    d.emit('ERROR', 'request_failed', component='reader')


def test_success_logs_follow_commit_and_discard_rollback(logs):
    engine = create_engine('sqlite://')
    with Session(engine) as session:
        with session.begin():
            d.after_commit(session, 'incident_committed', component='incidents', event_id='a'*32)
            assert not logs.getvalue()
        assert len(records(logs)) == 1
        with pytest.raises(RuntimeError), session.begin():
            d.after_commit(session, 'incident_committed', component='incidents', event_id='b'*32)
            raise RuntimeError()
        with session.begin():
            pass
    assert len(records(logs)) == 1


def test_savepoint_does_not_publish_before_outer_commit(logs):
    with Session(create_engine('sqlite://')) as session:
        with session.begin():
            d.after_commit(session, 'incident_committed', component='incidents', event_id='a'*32)
            with session.begin_nested():
                d.after_commit(session, 'incident_committed', component='incidents', event_id='b'*32)
            assert not logs.getvalue()
            with pytest.raises(RuntimeError), session.begin_nested():
                d.after_commit(session, 'incident_committed', component='incidents', event_id='c'*32)
                raise RuntimeError()
        assert [e['event_id'] for e in records(logs)] == ['a'*32, 'b'*32]


def test_parent_savepoint_rollback_discards_descendant_logs(logs):
    with Session(create_engine('sqlite://')) as session:
        with session.begin():
            outer = session.begin_nested()
            session.begin_nested()
            d.after_commit(session, 'incident_committed', component='incidents', event_id='a'*32)
            outer.rollback()
    assert not records(logs)


def test_closed_session_reuse_does_not_emit_abandoned_success(logs):
    with Session(create_engine('sqlite://')) as session:
        session.begin()
        d.after_commit(session, 'incident_committed', component='incidents', event_id='a'*32)
        session.close()
        with session.begin():
            pass
    assert not records(logs)


def test_observer_failure_retains_safe_validation_reason_and_watermark(logs, tmp_path):
    class Reader:
        def snapshot(self, *args):
            raise TronReadError('TRON solid head regressed')
    observer = Observer(tmp_path/'observer.sqlite3', Reader(), 'synthetic', now_ms=lambda: 2000, start_ms=1000)
    result = observer.run_once()
    assert result['error_code'] == 'SNAPSHOT_FAILED'
    assert result['checkpoint_ms'] == 1000
    failed = next(e for e in records(logs) if e['event'] == 'scan_failed')
    assert failed['reason_code'] == 'SOLID_HEAD_REGRESSED'
    assert failed['run_id'] == 1


def test_source_diagnostics_explain_199_second_block_age(logs):
    d.source_health(now_ms=199543, heartbeat=148230, observed=116539, solid_ms=0,
        max_age_seconds=120, head_limit=180, observation_id=3924,
        status='ERROR', stable=True, reconciliation='RECONCILIATION_UNVERIFIED', healthy=False,
        run_id=4368, fresh_until_ms=180000)
    row = records(logs)[-1]
    assert row['reason_code'] == 'SOLID_HEAD_STALE'
    assert row['solid_head_age_ms'] == 199543
    assert row['freshness_limit_ms'] == 180000
    assert row['observation_id'] == 3924
    assert row['run_id'] == 4368 and row['fresh_until_ms'] == 180000
    assert set(row['failed_conditions']) == {'SOLID_HEAD_STALE', 'SOURCE_RUN_ERROR', 'RECONCILIATION_PENDING'}
