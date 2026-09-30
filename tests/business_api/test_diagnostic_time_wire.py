from copy import deepcopy
from uuid import uuid4

import pytest
from pydantic import ValidationError

from app.api.client_diagnostics import DiagnosticBatch


def operation(kind='history_search'):
    return {
        'operation_id': str(uuid4()),
        'operation': kind,
        'observation_kind': 'final',
        'result': 'slow',
        'total_ms': 120,
        'stages': [
            {'stage': 'search_scan_started', 'elapsed_ms': 0},
            {'stage': 'search_first_hit', 'elapsed_ms': 50},
            {'stage': 'search_coverage_complete', 'elapsed_ms': 120},
        ],
        'lifecycle': 'foreground',
        'frame_attribution_complete': False,
        'scan_page_count': 2,
        'scan_row_count': 900,
        'first_hit_ms': 50,
        'full_coverage_ms': 120,
        'started_at_utc': '2026-09-28T12:00:00Z',
        'ended_at_utc': '2026-09-28T12:00:00.120Z',
        'clock_uncertainty_ms': 1050,
        'time_anchor_age_ms': 1000,
    }


def batch(record):
    return DiagnosticBatch.model_validate({
        'version': '0.4.21+2190', 'platform': 'android', 'operations': [record],
    })


def test_calibrated_history_search_record_is_closed_and_accepted():
    parsed = batch(operation())
    wire = parsed.model_dump(mode='json', exclude_unset=True)['operations'][0]
    assert wire['scan_row_count'] == 900
    assert wire['started_at_utc'] == '2026-09-28T12:00:00Z'


@pytest.mark.parametrize('change', [
    {'ended_at_utc': None},
    {'started_at_utc': '2026-09-28T12:00:00+08:00'},
    {'ended_at_utc': '2026-09-28T11:59:59Z'},
    {'ended_at_utc': '2026-09-28T12:00:05Z'},
    {'clock_uncertainty_ms': 2001},
    {'time_anchor_age_ms': 300001},
    {'scan_row_count': -1},
    {'scan_page_count': 100001},
    {'query_text': 'private message content'},
    {'room_id': '!private:example.test'},
])
def test_untrusted_or_sensitive_operation_fields_are_rejected(change):
    record = operation()
    record.update(change)
    with pytest.raises(ValidationError):
        batch(record)


def test_partial_calibrated_window_is_rejected():
    record = operation()
    del record['ended_at_utc']
    with pytest.raises(ValidationError):
        batch(record)


def test_keyboard_and_room_direction_are_required_and_closed():
    keyboard = operation('keyboard_transition')
    for name in ('scan_page_count', 'scan_row_count', 'first_hit_ms', 'full_coverage_ms'):
        keyboard.pop(name)
    keyboard['stages'] = [
        {'stage': 'keyboard_requested', 'elapsed_ms': 0},
        {'stage': 'keyboard_stable_frame', 'elapsed_ms': 120},
    ]
    with pytest.raises(ValidationError):
        batch(keyboard)
    keyboard['keyboard_direction'] = 'show'
    assert batch(keyboard).operations[0].keyboard_direction == 'show'
    keyboard['keyboard_direction'] = 'secret'
    with pytest.raises(ValidationError):
        batch(keyboard)

    route = deepcopy(keyboard)
    route['operation'] = 'room_local_frame'
    route.pop('keyboard_direction')
    route['stages'] = [
        {'stage': 'route_exit_requested', 'elapsed_ms': 0},
        {'stage': 'route_exit_frame', 'elapsed_ms': 120},
    ]
    with pytest.raises(ValidationError):
        batch(route)
    route['room_route_phase'] = 'leave'
    assert batch(route).operations[0].room_route_phase == 'leave'


def test_matrix_sync_timeline_envelope_count_is_bounded_and_not_a_message_label():
    sync = operation('matrix_sync')
    for name in ('scan_page_count', 'scan_row_count', 'first_hit_ms', 'full_coverage_ms'):
        sync.pop(name)
    sync['stages'] = [
        {'stage': 'sync_response_received', 'elapsed_ms': 10},
        {'stage': 'sync_processing_done', 'elapsed_ms': 120},
    ]
    sync['timeline_event_count'] = 50
    assert batch(sync).operations[0].timeline_event_count == 50
    sync['timeline_event_count'] = 100001
    with pytest.raises(ValidationError):
        batch(sync)
