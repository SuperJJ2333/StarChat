"""Exact, private handle lookup and bounded identity-free diagnostic output."""

import importlib.util
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'services/business-api'))

import pytest

from app.core.diagnostic_identity import diagnostic_ref


def tool():
    path = ROOT / 'scripts' / 'diagnostic_account_query.py'
    spec = importlib.util.spec_from_file_location('diagnostic_account_query', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Session:
    def __init__(self):
        self.statements = []

    def scalar(self, statement):
        self.statements.append(statement)
        assert 'users.username_normalized = ' in str(statement)
        assert 'LIKE' not in str(statement).upper()
        value = next(iter(statement.compile().params.values()))
        return '12345678-1234-4234-9234-123456789abc' if value == 'a1111123' else None


def test_exact_current_handle_resolves_immutable_subject_with_one_equality():
    module = tool()
    session = Session()
    current, previous = b'c' * 32, b'p' * 32
    refs = module.resolve_refs(session, 'A1111123', current, previous)
    assert refs == (
        diagnostic_ref(current, 'subject', '12345678-1234-4234-9234-123456789abc'),
        diagnostic_ref(previous, 'subject', '12345678-1234-4234-9234-123456789abc'),
    )
    assert len(session.statements) == 1
    for handle in ('a11111', 'oldhandle', '', 'x' * 65):
        with pytest.raises(LookupError, match='^Account not found$'):
            module.resolve_refs(session, handle, current, previous)


def test_private_summary_bounds_coverage_and_never_prints_raw_refs():
    module = tool()
    subject_ref, device_ref = 'a' * 64, 'b' * 64
    row = {
        'event': 'client_diagnostics', 'version': '0.4.20+2190',
        'platform': 'android', 'subject_ref': subject_ref,
        'device_ref': device_ref, 'operations': [{
            'operation_id': '12345678-1234-4234-9234-123456789abc',
            'operation': 'matrix_sync', 'result': 'slow', 'total_ms': 8000,
            'frame_attribution_complete': False,
            'stages': [{'stage': 'sync_processing_done', 'elapsed_ms': 8000}],
            'lifecycle': 'foreground', 'timeline_event_count': 100,
            'started_at_utc': '2026-09-28T08:00:00Z',
            'ended_at_utc': '2026-09-28T08:00:08Z',
            'clock_uncertainty_ms': 1000, 'time_anchor_age_ms': 1000,
        }],
    }
    line = json.dumps({'log': json.dumps(row) + '\n', 'stream': 'stdout',
                       'time': '2026-09-28T08:01:00Z'})
    now = datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc)
    result = module.summarize_account_logs([line], refs=(subject_ref,),
                                           since_hours=1, now=now)
    assert result['matched_batches'] == 1
    assert result['coverage_first_utc'] == '2026-09-28T08:01:00Z'
    assert result['coverage_last_utc'] == '2026-09-28T08:01:00Z'
    assert result['coverage_incomplete'] is True
    assert result['retained_first_utc'] == '2026-09-28T08:01:00Z'
    assert result['time_uncertain_count'] == 0
    assert result['operations'][0]['device'] == 'device_1'
    assert result['operations'][0]['operation'] == 'matrix_sync'
    assert result['release_batches'] == [
        {'version': '0.4.20+2190', 'platform': 'android', 'count': 1}]
    assert result['device_timeline'][0]['version'] == '0.4.20+2190'
    assert result['device_timeline'][0]['platform'] == 'android'
    serialized = json.dumps(result)
    assert subject_ref not in serialized and device_ref not in serialized
    assert '12345678-1234-4234-9234-123456789abc' not in serialized
    retried = module.summarize_account_logs([line, line], refs=(subject_ref,),
                                            since_hours=1, now=now)
    assert retried['operations'][0]['count'] == 1
    assert retried['duplicate_operations'] == 1
    unrelated = json.dumps({'log': json.dumps({
        'event': 'server_request_timeline',
        'request_id': '12345678-1234-4234-9234-123456789abd',
    }), 'stream': 'stdout', 'time': '2026-09-28T08:01:01Z'})
    mixed = module.summarize_account_logs([unrelated, line], refs=(subject_ref,),
                                          since_hours=1, now=now)
    assert mixed['rejected_lines'] == 1
    assert mixed['matched_batches'] == 1
    row['operations'][0].pop('started_at_utc')
    row['operations'][0].pop('ended_at_utc')
    row['operations'][0].pop('clock_uncertainty_ms')
    row['operations'][0].pop('time_anchor_age_ms')
    delayed = json.dumps({'log': json.dumps(row), 'stream': 'stdout',
                          'time': '2026-09-28T08:01:00Z'})
    assert module.summarize_account_logs([delayed], refs=(subject_ref,),
                                         since_hours=1, now=now)['time_uncertain_count'] == 1


def test_retained_log_window_must_reach_requested_cutoff():
    module = tool()
    subject_ref = 'a' * 64
    matched = json.dumps({'log': json.dumps({
        'event': 'client_diagnostics', 'version': '0.4.21+2190',
        'platform': 'android', 'subject_ref': subject_ref,
        'diagnostic_loss': {
            'sample_id': '12345678-1234-4234-9234-123456789abc',
            'dropped_events': 1, 'dropped_operations': 0,
            'dropped_frames': 0,
        },
    }), 'stream': 'stdout', 'time': '2026-09-28T08:01:00Z'})
    older = json.dumps({'log': json.dumps({'event': 'service_starting'}),
                        'stream': 'stdout', 'time': '2026-09-28T06:59:59Z'})
    now = datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc)
    partial = module.summarize_account_logs([matched], refs=(subject_ref,),
                                            since_hours=1, now=now)
    assert partial['coverage_incomplete'] is True
    complete = module.summarize_account_logs([older, matched], refs=(subject_ref,),
                                             since_hours=1, now=now)
    assert complete['coverage_incomplete'] is False
    assert complete['retained_first_utc'] == '2026-09-28T06:59:59Z'
    assert complete['coverage_first_utc'] == '2026-09-28T08:01:00Z'


def test_private_timeline_direct_request_precedes_coincidence_and_hides_ids():
    module = tool()
    subject_ref, device_ref = 'a' * 64, 'b' * 64
    operation_id = '12345678-1234-4234-9234-123456789abc'
    request_id = '12345678-1234-4234-9234-123456789abd'
    keyboard_id = '12345678-1234-4234-9234-123456789abe'
    room_id = '12345678-1234-4234-9234-123456789abf'

    def operation(op_id, kind, duration, **extra):
        return {'operation_id': op_id, 'operation': kind, 'result': 'slow',
                'total_ms': duration, 'stages': [], 'lifecycle': 'foreground',
                'frame_attribution_complete': False,
                **extra}

    batch = {
        'event': 'client_diagnostics', 'version': '0.4.21+2190',
        'platform': 'android', 'subject_ref': subject_ref, 'device_ref': device_ref,
        'operations': [
            operation(operation_id, 'api_request', 1000,
                      started_at_utc='2026-09-28T08:00:00Z',
                      ended_at_utc='2026-09-28T08:00:01Z',
                      clock_uncertainty_ms=1000, time_anchor_age_ms=1000),
            operation(keyboard_id, 'keyboard_transition', 200,
                      keyboard_direction='show',
                      started_at_utc='2026-09-28T08:00:00.120Z',
                      ended_at_utc='2026-09-28T08:00:00.320Z',
                      clock_uncertainty_ms=1000, time_anchor_age_ms=1000),
            operation(room_id, 'room_local_frame', 100,
                      room_route_phase='enter'),
        ],
        'network_requests': [{
            'request_id': request_id, 'operation_id': operation_id,
            'version': '0.4.21+2190', 'platform': 'android',
            'target': 'primary_api', 'network': 'wifi', 'method': 'GET',
            'endpoint_category': 'profile',
            'started_at': '2026-09-27T08:00:00Z',
            'elapsed_ms': 8000, 'phase': 'awaiting_headers',
            'reason': 'timeout', 'timeout_budget_ms': 8000,
            'timeout_lateness_ms': 0,
        }],
    }
    server = {
        'event': 'server_request_timeline', 'request_id': request_id,
        'server_started_at': '2026-09-28T08:00:00.100Z',
        'elapsed_ms': 100, 'method': 'GET', 'endpoint_category': 'profile',
        'route_template': '/api/v1/profile/me', 'termination': 'complete',
        'http_status': 200, 'headers_prepared_ms': 80,
        'body_prepared_ms': 90, 'send_finished_ms': 100,
    }

    def docker(row, at):
        return json.dumps({'log': json.dumps(row), 'stream': 'stdout', 'time': at})

    result = module.summarize_account_logs([
        docker(server, '2026-09-28T08:00:00.200Z'),
        docker(batch, '2026-09-28T08:01:00Z'),
    ], refs=(subject_ref,), since_hours=1,
        now=datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc))
    assert result['request_uuid_matches'] == 1
    assert result['coincident_operations'] == 1
    assert result['time_uncertain_count'] == 1
    rows = result['device_timeline']
    assert len(rows) == 4
    assert rows[0]['kind'] == 'operation' and rows[0]['operation'] == 'api_request'
    assert all(row['device'] == 'device_1' for row in rows)
    assert all(row['version'] == '0.4.21+2190' and row['platform'] == 'android'
               for row in rows)
    by_operation = {row['operation']: row for row in rows if row['kind'] == 'operation'}
    assert by_operation['api_request']['correlation'] == 'request_uuid_match'
    assert by_operation['keyboard_transition']['correlation'] == 'coincident'
    assert by_operation['room_local_frame']['correlation'] == 'time_uncertain'
    assert next(row for row in rows if row['kind'] == 'network_request')['correlation'] == 'request_uuid_match'
    serialized = json.dumps(result)
    for private in (subject_ref, device_ref, operation_id, request_id,
                    keyboard_id, room_id, '/api/v1/profile/me'):
        assert private not in serialized
    unrelated_server = {**server,
                        'request_id': '12345678-1234-4234-9234-123456789ac0'}
    unrelated = module.summarize_account_logs([
        docker(unrelated_server, '2026-09-28T08:00:00.200Z'),
        docker(batch, '2026-09-28T08:01:00Z'),
    ], refs=(subject_ref,), since_hours=1,
        now=datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc))
    assert unrelated['request_uuid_matches'] == 0
    assert next(row for row in unrelated['device_timeline']
                if row.get('operation') == 'keyboard_transition')['correlation'] == 'none'
    module._MAX_TIMELINE_ROWS = 2
    bounded = module.summarize_account_logs([
        docker(server, '2026-09-28T08:00:00.200Z'),
        docker(batch, '2026-09-28T08:01:00Z'),
    ], refs=(subject_ref,), since_hours=1,
        now=datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc))
    assert bounded['timeline_truncated'] is True
    assert len(bounded['device_timeline']) == 2


def test_private_timeline_does_not_correlate_other_devices_network_window():
    module = tool()
    subject_ref, device_a, device_b = 'a' * 64, 'b' * 64, 'c' * 64
    keyboard_id = '12345678-1234-4234-9234-123456789ab1'
    api_id = '12345678-1234-4234-9234-123456789ab2'
    request_id = '12345678-1234-4234-9234-123456789ab3'

    def docker(row, at):
        return json.dumps({'log': json.dumps(row), 'stream': 'stdout', 'time': at})

    batch_a = {
        'event': 'client_diagnostics', 'version': '0.4.21+2190',
        'platform': 'android', 'subject_ref': subject_ref, 'device_ref': device_a,
        'operations': [{
            'operation_id': keyboard_id, 'operation': 'keyboard_transition',
            'result': 'slow', 'total_ms': 200, 'stages': [],
            'lifecycle': 'foreground', 'frame_attribution_complete': False,
            'keyboard_direction': 'show',
            'started_at_utc': '2026-09-28T08:00:00.120Z',
            'ended_at_utc': '2026-09-28T08:00:00.320Z',
            'clock_uncertainty_ms': 1000, 'time_anchor_age_ms': 1000,
        }],
    }
    batch_b = {
        'event': 'client_diagnostics', 'version': '0.4.21+2190',
        'platform': 'android', 'subject_ref': subject_ref, 'device_ref': device_b,
        'operations': [{
            'operation_id': api_id, 'operation': 'api_request',
            'result': 'slow', 'total_ms': 1000, 'stages': [],
            'lifecycle': 'foreground', 'frame_attribution_complete': False,
            'started_at_utc': '2026-09-28T08:00:00Z',
            'ended_at_utc': '2026-09-28T08:00:01Z',
            'clock_uncertainty_ms': 1000, 'time_anchor_age_ms': 1000,
        }],
        'network_requests': [{
            'request_id': request_id, 'operation_id': api_id,
            'version': '0.4.21+2190', 'platform': 'android',
            'target': 'primary_api', 'network': 'wifi', 'method': 'GET',
            'endpoint_category': 'profile',
            'started_at': '2026-09-27T08:00:00Z',
            'elapsed_ms': 8000, 'phase': 'awaiting_headers',
            'reason': 'timeout', 'timeout_budget_ms': 8000,
            'timeout_lateness_ms': 0,
        }],
    }
    server = {
        'event': 'server_request_timeline', 'request_id': request_id,
        'server_started_at': '2026-09-28T08:00:00.100Z',
        'elapsed_ms': 100, 'method': 'GET', 'endpoint_category': 'profile',
        'route_template': '/api/v1/profile/me', 'termination': 'complete',
        'http_status': 200, 'headers_prepared_ms': 80,
        'body_prepared_ms': 90, 'send_finished_ms': 100,
    }
    result = module.summarize_account_logs([
        docker(server, '2026-09-28T08:00:00.200Z'),
        docker(batch_a, '2026-09-28T08:01:00Z'),
        docker(batch_b, '2026-09-28T08:01:01Z'),
    ], refs=(subject_ref,), since_hours=1,
        now=datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc))
    operations = {row['operation']: row for row in result['device_timeline']
                  if row['kind'] == 'operation'}
    assert operations['keyboard_transition']['device'] == 'device_1'
    assert operations['keyboard_transition']['correlation'] == 'none'
    assert operations['api_request']['device'] == 'device_2'
    assert operations['api_request']['correlation'] == 'request_uuid_match'
    assert result['coincident_operations'] == 0
    assert result['request_uuid_matches'] == 1
    serialized = json.dumps(result)
    for private in (subject_ref, device_a, device_b, keyboard_id, api_id, request_id):
        assert private not in serialized
    unknown_device = {key: value for key, value in batch_a.items() if key != 'device_ref'}
    unknown = module.summarize_account_logs([
        docker(server, '2026-09-28T08:00:00.200Z'),
        docker(unknown_device, '2026-09-28T08:01:00Z'),
        docker(batch_b, '2026-09-28T08:01:01Z'),
    ], refs=(subject_ref,), since_hours=1,
        now=datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc))
    keyboard = next(row for row in unknown['device_timeline']
                    if row.get('operation') == 'keyboard_transition')
    assert keyboard['device'] == 'device_unknown'
    assert keyboard['correlation'] == 'none'
    assert unknown['coincident_operations'] == 0


def test_private_query_accepts_strict_docker_logs_timestamps():
    module = tool()
    subject_ref = 'a' * 64
    row = {
        'event': 'client_diagnostics', 'version': '0.4.21+2190',
        'platform': 'android', 'subject_ref': subject_ref,
        'diagnostic_loss': {
            'sample_id': '12345678-1234-4234-9234-123456789abc',
            'dropped_events': 1, 'dropped_operations': 0,
            'dropped_frames': 0,
        },
    }
    rendered = json.dumps(row)
    valid = f'2026-09-28T08:01:00.123456789Z {rendered}\n'
    at, parsed = module._docker_batch(valid)
    assert at == datetime.fromisoformat('2026-09-28T08:01:00.123456+00:00')
    assert parsed == row
    now = datetime(2026, 9, 28, 8, 2, tzinfo=timezone.utc)
    result = module.summarize_account_logs([valid], refs=(subject_ref,),
                                           since_hours=1, now=now)
    assert result['matched_batches'] == 1
    assert result['retained_first_utc'] == '2026-09-28T08:01:00Z'
    for invalid in (rendered, f'2026-09-28T08:01:00+08:00 {rendered}',
                    f'2026-09-28T08:01:00Z not-json'):
        with pytest.raises(ValueError):
            module._docker_batch(invalid)


@pytest.mark.parametrize('hours', [0, 169, True])
def test_private_query_rejects_unbounded_windows(hours):
    with pytest.raises(ValueError):
        tool().summarize_account_logs([], refs=('a' * 64,), since_hours=hours)
