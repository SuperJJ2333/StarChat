"""Exact, private handle lookup and bounded identity-free diagnostic output."""

import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest

from app.core.diagnostic_identity import diagnostic_ref


ROOT = Path(__file__).resolve().parents[2]


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
    assert result['time_uncertain_count'] == 0
    assert result['operations'][0]['device'] == 'device_1'
    assert result['operations'][0]['operation'] == 'matrix_sync'
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
    assert mixed['rejected_lines'] == 0
    assert mixed['matched_batches'] == 1
    row['operations'][0].pop('started_at_utc')
    row['operations'][0].pop('ended_at_utc')
    row['operations'][0].pop('clock_uncertainty_ms')
    row['operations'][0].pop('time_anchor_age_ms')
    delayed = json.dumps({'log': json.dumps(row), 'stream': 'stdout',
                          'time': '2026-09-28T08:01:00Z'})
    assert module.summarize_account_logs([delayed], refs=(subject_ref,),
                                         since_hours=1, now=now)['time_uncertain_count'] == 1


@pytest.mark.parametrize('hours', [0, 169, True])
def test_private_query_rejects_unbounded_windows(hours):
    with pytest.raises(ValueError):
        tool().summarize_account_logs([], refs=('a' * 64,), since_hours=hours)
