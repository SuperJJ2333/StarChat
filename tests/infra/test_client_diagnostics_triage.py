"""Read-only aggregate diagnostics must not export client identities or raw logs."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[2]


def triage():
    path = ROOT / 'scripts' / 'client_diagnostics_triage.py'
    spec = importlib.util.spec_from_file_location('client_diagnostics_triage', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def operation(**changes):
    value = {
        'operation_id': '12345678-1234-4234-9234-123456789abc',
        'operation': 'matrix_sync', 'lifecycle': 'foreground',
        'stages': [{'stage': 'sync_response_wait_started', 'elapsed_ms': 0}],
        'observation_kind': 'final', 'result': 'failed', 'total_ms': 8000,
        'network_error': 'request_timeout',
        'slow_frame_count': 0, 'slow_build_count': 0, 'slow_raster_count': 0,
    }
    value.update(changes)
    return value


def frame_window(**changes):
    value = {
        'window_id': '12345678-1234-4234-9234-123456789abd',
        'window_start': '2026-09-27T06:00:00Z',
        'window_end': '2026-09-27T06:00:01Z',
        'active_tab': 'messages', 'budget_us': 16667, 'frame_count': 10,
        'slow_frame_count': 2, 'slow_build_count': 2, 'slow_raster_count': 1,
        'max_build_us': 29000, 'max_raster_us': 19000,
    }
    value.update(changes)
    return value


def loss(**changes):
    value = {
        'sample_id': '12345678-1234-4234-9234-123456789abe',
        'dropped_events': 1, 'dropped_operations': 2, 'dropped_frames': 3,
    }
    value.update(changes)
    return value


def event(**changes):
    value = {
        'operation_id': '12345678-1234-4234-9234-123456789ac0',
        'stage': 'matrix_sync_soft_kick', 'error': 'slow',
        'elapsed_ms': 8000, 'count': 3,
    }
    value.update(changes)
    return value


def batch(**changes):
    value = {
        'event': 'client_diagnostics', 'version': '0.4.19+2188',
        'platform': 'android', 'operations': [operation()],
        'frame_windows': [frame_window()], 'diagnostic_loss': loss(),
    }
    value.update(changes)
    return value


def docker_line(value):
    return json.dumps({'log': json.dumps(value) + '\n', 'stream': 'stdout',
                       'time': '2026-09-27T06:01:00Z'})


def test_server_identity_refs_are_validated_and_absent_from_generic_triage():
    tool = triage()
    subject_ref, device_ref = 'a' * 64, 'b' * 64
    accepted = batch(subject_ref=subject_ref, device_ref=device_ref)
    result = tool.summarize_logs([docker_line(accepted)])
    assert result['coverage']['accepted_batches'] == 1
    assert subject_ref not in json.dumps(result)
    assert device_ref not in json.dumps(result)
    malformed = batch(subject_ref='A' * 64)
    result = tool.summarize_logs([docker_line(malformed)])
    assert result['coverage']['rejected_lines'] == 1


def test_aggregates_closed_operation_frames_and_loss_by_original_release():
    tool = triage()
    result = tool.summarize_logs([docker_line(batch())])
    assert result['by_client'] == [{
        'version': '0.4.19+2188', 'platform': 'android',
        'events': [],
        'operations': [{
            'operation': 'matrix_sync', 'result': 'failed',
            'network_error': 'request_timeout',
            'last_stage': 'sync_response_wait_started', 'count': 1,
        }],
        'frame_windows': [{
            'active_tab': 'messages', 'window_count': 1,
            'frame_count': 10, 'slow_frame_count': 2,
            'slow_build_count': 2, 'slow_raster_count': 1,
            'slow_ratio': 0.2,
        }],
        'diagnostic_loss': {
            'sample_count': 1, 'dropped_events': 1,
            'dropped_operations': 2, 'dropped_frames': 3,
        },
    }]
    assert result['coverage']['accepted_batches'] == 1


def test_deduplicates_retried_ids_without_double_counting():
    tool = triage()
    same = docker_line(batch())
    result = tool.summarize_logs([same, same])
    row = result['by_client'][0]
    assert row['operations'][0]['count'] == 1
    assert row['frame_windows'][0]['window_count'] == 1
    assert row['diagnostic_loss']['sample_count'] == 1
    assert result['coverage']['duplicate_operations'] == 1
    assert result['coverage']['duplicate_frame_windows'] == 1
    assert result['coverage']['duplicate_loss_samples'] == 1


@pytest.mark.parametrize('change', [
    {'operations': [operation(result='slow')]},
    {'frame_windows': [frame_window(frame_count=11)]},
    {'diagnostic_loss': loss(dropped_events=7)},
    {'version': '0.4.20+2189'},
])
def test_quarantines_conflicting_identity_across_batches_without_revealing_it(change):
    tool = triage()
    result = tool.summarize_logs([docker_line(batch()), docker_line(batch(**change))])
    assert result['coverage']['coverage_incomplete'] is True
    assert sum(result['coverage'][key] for key in (
        'conflicting_operations', 'conflicting_frame_windows',
        'conflicting_loss_samples')) >= 1
    assert '12345678' not in json.dumps(result)


def test_ignores_nonfinal_observation_without_inventing_a_result():
    tool = triage()
    checkpoint = operation(observation_kind='checkpoint',
                           observed_elapsed_ms=350, frame_attribution_complete=False)
    checkpoint.pop('result')
    checkpoint.pop('total_ms')
    checkpoint.pop('slow_frame_count')
    checkpoint.pop('slow_build_count')
    checkpoint.pop('slow_raster_count')
    result = tool.summarize_logs([json.dumps(batch(operations=[checkpoint]))])
    assert result['by_client'][0]['operations'] == []
    assert result['coverage']['ignored_nonfinal_operations'] == 1


@pytest.mark.parametrize('change', [
    {'version': 'private-account'},
    {'platform': 'Windows: private-account'},
    {'operations': [operation(network_error='private-secret')]},
    {'operations': [operation(stages=[{'stage': 'private-url', 'elapsed_ms': 0}])]},
    {'operations': [operation(total_ms=True)]},
    {'frame_windows': [frame_window(window_end='2026-02-30T06:00:01Z')]},
    {'frame_windows': [frame_window(frame_count=True)]},
    {'frame_windows': [frame_window(active_tab='room/private')]},
    {'diagnostic_loss': loss(dropped_events=-1)},
    {'secret': 'private-token'},
])
def test_rejects_unclosed_or_out_of_bounds_metadata_without_leaking(change):
    tool = triage()
    result = tool.summarize_logs([docker_line(batch(**change))])
    assert result['by_client'] == []
    assert result['coverage']['rejected_lines'] == 1
    wire = json.dumps(result)
    for private in ('private-account', 'private-secret', 'private-url',
                    'room/private', 'private-token', '12345678'):
        assert private not in wire


def test_unrelated_plaintext_service_log_does_not_claim_diagnostic_loss():
    tool = triage()
    result = tool.summarize_logs([
        'INFO: 127.0.0.1 - "GET /api/v1/health/ready HTTP/1.1" 200',
        docker_line(batch(diagnostic_loss=None)),
    ])
    assert result['coverage']['accepted_batches'] == 1
    assert result['coverage']['ignored_lines'] == 1
    assert result['coverage']['rejected_lines'] == 0
    assert result['coverage']['coverage_incomplete'] is False


def test_malformed_diagnostic_marked_rejected_without_echoing_text():
    tool = triage()
    result = tool.summarize_logs(['client_diagnostics PRIVATE not-json'])
    assert result['coverage']['ignored_lines'] == 0
    assert result['coverage']['rejected_lines'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert 'PRIVATE' not in json.dumps(result)


def test_recovers_complete_diagnostic_prefix_with_interleaved_service_text():
    tool = triage()
    valid = batch(frame_windows=None, diagnostic_loss=None)
    line = json.dumps(valid) + ' PRIVATE unrelated service text'
    result = tool.summarize_logs([line])
    assert result['coverage']['accepted_batches'] == 1
    assert result['coverage']['rejected_lines'] == 1
    assert result['coverage']['contaminated_lines'] == 1
    assert result['coverage']['unparsed_suffix_lines'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert result['by_client'][0]['operations'][0]['count'] == 1
    assert 'PRIVATE' not in json.dumps(result)


def test_recovers_valid_prefix_in_docker_envelope_without_echoing_suffix():
    tool = triage()
    payload = json.dumps(batch(frame_windows=None, diagnostic_loss=None)) + ' PRIVATE tail\n'
    line = json.dumps({'log': payload, 'stream': 'stdout',
                       'time': '2026-09-27T06:01:00Z'})
    result = tool.summarize_logs([line])
    assert result['coverage']['accepted_batches'] == 1
    assert result['coverage']['contaminated_lines'] == 1
    assert result['coverage']['unparsed_suffix_lines'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert 'PRIVATE' not in json.dumps(result)


def test_concatenated_valid_diagnostics_flags_possible_suffix_loss():
    tool = triage()
    first = batch(frame_windows=None, diagnostic_loss=None)
    second = batch(operations=[operation(operation_id='12345678-1234-4234-9234-123456789abf')],
                   frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([json.dumps(first) + json.dumps(second)])
    assert result['coverage']['accepted_batches'] == 1
    assert result['coverage']['contaminated_lines'] == 1
    assert result['coverage']['unparsed_suffix_lines'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert result['by_client'][0]['operations'][0]['count'] == 1


def test_malformed_diagnostic_prefix_is_not_recovered():
    tool = triage()
    invalid = batch(secret='PRIVATE')
    result = tool.summarize_logs([json.dumps(invalid) + ' trailing text'])
    assert result['coverage']['accepted_batches'] == 0
    assert result['coverage']['rejected_lines'] == 1
    assert result['by_client'] == []
    assert 'PRIVATE' not in json.dumps(result)


def test_contaminated_prefix_still_uses_identity_deduplication():
    tool = triage()
    row = batch(operations=[operation(operation='message_send', attempt_index=0)],
                frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([json.dumps(row) + ' service text', json.dumps(row)])
    assert result['coverage']['accepted_batches'] == 2
    assert result['coverage']['contaminated_lines'] == 1
    assert result['coverage']['duplicate_operations'] == 1
    assert result['by_client'][0]['operations'][0]['count'] == 1


def test_bounded_input_marks_truncation_and_does_not_parse_later_private_text():
    tool = triage()
    result = tool.summarize_logs([docker_line(batch()), 'private-token'], max_lines=1)
    assert result['coverage']['truncated'] is True
    assert result['coverage']['scanned_lines'] == 1
    assert 'private-token' not in json.dumps(result)


def test_huge_line_is_rejected_without_echo():
    tool = triage()
    result = tool.summarize_logs(['private-token' * 10000])
    assert result['coverage']['oversized_lines'] == 1
    assert 'private-token' not in json.dumps(result)


def test_record_cap_marks_truncation_but_still_quarantines_conflict_in_seen_id():
    tool = triage()
    first = batch(operations=[operation()], frame_windows=None, diagnostic_loss=None)
    second = batch(operations=[operation(result='slow')],
                   frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(second)], max_records=1)
    assert result['coverage']['conflicting_operations'] == 1
    assert result['coverage']['identity_ambiguous'] is True
    assert result['by_client'] == []


def test_record_cap_reports_loss_of_coverage_for_new_id():
    tool = triage()
    first = batch(operations=[operation()], frame_windows=None, diagnostic_loss=None)
    later = batch(operations=[operation(operation_id='12345678-1234-4234-9234-123456789abf')],
                  frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(later)], max_records=1)
    assert result['coverage']['truncated'] is True
    assert result['coverage']['scanned_lines'] == 2
    assert result['by_client'][0]['operations'][0]['count'] == 1


@pytest.mark.parametrize('span_kwargs', [
    ({'operation': 'message_send', 'attempt_index': 0},
     {'operation': 'message_send', 'attempt_index': 1}),
    ({'operation': 'call_active', 'window_index': 0},
     {'operation': 'call_active', 'window_index': 1}),
])
def test_same_correlation_id_with_distinct_explicit_span_indices_counts_both(span_kwargs):
    tool = triage()
    rows = [operation(**kwargs) for kwargs in span_kwargs]
    result = tool.summarize_logs([docker_line(batch(operations=rows,
                                                  frame_windows=None,
                                                  diagnostic_loss=None))])
    assert result['by_client'][0]['operations'][0]['count'] == 2
    assert result['coverage']['duplicate_operations'] == 0
    assert result['coverage']['identity_ambiguous'] is False


def test_exact_retry_of_indexed_span_counts_once_without_ambiguity():
    tool = triage()
    row = batch(operations=[operation(operation='message_send', attempt_index=0)],
                frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(row), docker_line(row)])
    assert result['by_client'][0]['operations'][0]['count'] == 1
    assert result['coverage']['duplicate_operations'] == 1
    assert result['coverage']['identity_ambiguous'] is False


def test_conflicting_indexed_span_is_quarantined_without_hiding_other_attempt():
    tool = triage()
    first = batch(operations=[operation(operation='message_send', attempt_index=0),
                              operation(operation='message_send', attempt_index=1)],
                  frame_windows=None, diagnostic_loss=None)
    second = batch(operations=[operation(operation='message_send', attempt_index=0,
                                         result='slow')],
                   frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(second)])
    assert result['by_client'][0]['operations'][0]['count'] == 1
    assert result['coverage']['conflicting_operations'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert result['coverage']['identity_ambiguous'] is False


def test_unindexed_exact_repeat_is_ambiguous_even_if_payload_is_equal():
    tool = triage()
    row = batch(operations=[operation()], frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(row), docker_line(row)])
    assert result['by_client'][0]['operations'][0]['count'] == 1
    assert result['coverage']['identity_ambiguous'] is True
    assert result['coverage']['operation_count_semantics'] == 'accepted_span_lower_bound'
    assert result['coverage']['coverage_incomplete'] is True


def test_unindexed_same_id_different_span_is_quarantined_and_marked_ambiguous():
    tool = triage()
    first = batch(operations=[operation()], frame_windows=None, diagnostic_loss=None)
    second = batch(operations=[operation(total_ms=9000)],
                   frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(second)])
    assert result['by_client'] == []
    assert result['coverage']['identity_ambiguous'] is True
    assert result['coverage']['conflicting_operations'] == 1
    assert result['coverage']['coverage_incomplete'] is True


@pytest.mark.parametrize('field,first,second,conflict_name', [
    ('frame_windows', [frame_window()], [frame_window(frame_count=11)],
     'conflicting_frame_windows'),
    ('diagnostic_loss', loss(), loss(dropped_events=7),
     'conflicting_loss_samples'),
])
def test_window_and_loss_conflicts_drop_both_versions(field, first, second, conflict_name):
    tool = triage()
    first_batch = batch(operations=[], frame_windows=None, diagnostic_loss=None)
    second_batch = dict(first_batch)
    first_batch[field] = first
    second_batch[field] = second
    result = tool.summarize_logs([docker_line(first_batch), docker_line(second_batch)])
    assert result['by_client'] == []
    assert result['coverage'][conflict_name] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert '12345678' not in json.dumps(result)


def test_cli_reads_explicit_service_root_and_emits_only_synthetic_aggregates():
    source = docker_line(batch(operations=[operation(operation='message_send',
                                                      attempt_index=0)],
                               frame_windows=None, diagnostic_loss=None))
    command = [sys.executable, str(ROOT / 'scripts' / 'client_diagnostics_triage.py'),
               '--service-root', str(ROOT / 'services' / 'business-api')]
    completed = subprocess.run(command, input=source, text=True, capture_output=True,
                               cwd=ROOT.parent, check=False)
    assert completed.returncode == 0, completed.stderr
    result = json.loads(completed.stdout)
    assert result['by_client'][0]['operations'][0]['count'] == 1
    assert result['coverage']['identity_ambiguous'] is False
    assert '12345678' not in completed.stdout
    assert 'private' not in completed.stdout


def test_explicit_invalid_service_root_is_rejected_instead_of_using_default():
    tool = triage()
    with pytest.raises(ValueError, match='Invalid service root'):
        tool.summarize_logs([docker_line(batch())], service_root=ROOT)


@pytest.mark.parametrize('stage,error', [
    ('matrix_sync_soft_kick', 'slow'),
    ('matrix_sync_hard_restart', 'timeout'),
])
def test_pure_watchdog_event_is_visible_by_release_stage_and_error(stage, error):
    tool = triage()
    row = batch(events=[event(stage=stage, error=error)], operations=[], frame_windows=None,
                diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(row)])
    assert result['by_client'] == [{
        'version': '0.4.19+2188', 'platform': 'android',
        'events': [{'stage': stage, 'error': error,
                    'sample_count': 1, 'reported_count': 3}],
        'operations': [], 'frame_windows': [],
        'diagnostic_loss': {'sample_count': 0, 'dropped_events': 0,
                            'dropped_operations': 0, 'dropped_frames': 0},
    }]
    assert result['coverage']['event_count_semantics'] == 'accepted_distinct_ids_and_reported_count_not_unique_incidents'
    assert '12345678' not in json.dumps(result)


def test_exact_event_retry_same_id_does_not_double_count_reported_occurrences():
    tool = triage()
    row = batch(events=[event()], operations=[], frame_windows=None,
                diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(row), docker_line(row)])
    assert result['by_client'][0]['events'][0]['sample_count'] == 1
    assert result['by_client'][0]['events'][0]['reported_count'] == 3
    assert result['coverage']['duplicate_events'] == 1
    assert result['coverage']['event_identity_ambiguous'] is False


def test_same_event_id_changed_count_is_quarantined_without_crashing_report():
    tool = triage()
    first = batch(events=[event()], operations=[], frame_windows=None,
                  diagnostic_loss=None)
    changed = batch(events=[event(count=4)], operations=[], frame_windows=None,
                    diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(changed)])
    assert result['by_client'] == []
    assert result['coverage']['conflicting_events'] == 1
    assert result['coverage']['coverage_incomplete'] is True
    assert '12345678' not in json.dumps(result)


def test_identical_event_with_new_random_id_is_marked_ambiguous():
    tool = triage()
    first = batch(events=[event()], operations=[], frame_windows=None,
                  diagnostic_loss=None)
    repeated = batch(events=[event(operation_id='12345678-1234-4234-9234-123456789ac1')],
                     operations=[], frame_windows=None, diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(first), docker_line(repeated)])
    assert result['by_client'][0]['events'][0]['sample_count'] == 2
    assert result['by_client'][0]['events'][0]['reported_count'] == 6
    assert result['coverage']['event_identity_ambiguous'] is True
    assert result['coverage']['coverage_incomplete'] is True


@pytest.mark.parametrize('invalid', [
    event(stage='room/private'),
    event(error='secret-token'),
    event(count=1000001),
    {**event(), 'path': '/private/file'},
])
def test_invalid_event_metadata_never_enters_aggregate(invalid):
    tool = triage()
    row = batch(events=[invalid], operations=[], frame_windows=None,
                diagnostic_loss=None)
    result = tool.summarize_logs([docker_line(row)])
    assert result['by_client'] == []
    assert result['coverage']['rejected_lines'] == 1
    wire = json.dumps(result)
    for private in ('room/private', 'secret-token', '/private/file', '12345678'):
        assert private not in wire
