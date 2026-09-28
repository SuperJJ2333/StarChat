import importlib.util
import io
import json
import signal
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def module():
    path = ROOT / 'scripts/collect_network_diagnostics.py'
    assert path.is_file(), 'Safe network collection is not implemented'
    spec = importlib.util.spec_from_file_location('network_collection_tested', path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def sample():
    return dict(sample_id='00000000-0000-4000-8000-000000000001', version='0.4.6+2165',
                platform='android', window_start='2026-09-25T18:00:00Z',
                window_end='2026-09-25T18:01:00Z', target='primary_api', network='wifi',
                attempts=2, http_2xx=1, http_3xx=0, http_4xx=1, http_5xx=0,
                network_errors=0, timeouts=0, cancelled=0,
                success_latency_buckets=[1] + [0] * 8)


def envelope():
    return {'event': 'client_diagnostics', 'version': '0.4.14+2181', 'platform': 'ios',
            'events': [], 'networks': [sample()]}


def test_server_refs_are_validated_but_never_exported():
    data = envelope()
    data.update(subject_ref='a' * 64, device_ref='b' * 64)
    result = module().sanitize_logs([json.dumps(data)])
    assert result['metadata']['exported_samples'] == 1
    assert 'a' * 64 not in json.dumps(result)
    assert 'b' * 64 not in json.dumps(result)
    data['subject_ref'] = 'A' * 64
    assert module().sanitize_logs([json.dumps(data)])['metadata']['rejected_lines'] == 1


def operation():
    return {'operation_id': '00000000-0000-4000-8000-000000000002',
            'operation': 'message_send', 'stages': [], 'lifecycle': 'foreground',
            'result': 'success', 'total_ms': 10, 'slow_frame_count': 0,
             'slow_build_count': 0, 'slow_raster_count': 0}


def request_failure():
    return {'request_id': '00000000-0000-4000-8000-000000000003',
            'version': '0.4.14+2181', 'platform': 'ios', 'target': 'primary_api',
            'network': 'wifi', 'method': 'GET', 'endpoint_category': 'contacts',
            'started_at': '2026-09-25T18:00:00Z', 'elapsed_ms': 8000,
            'phase': 'awaiting_headers', 'reason': 'timeout',
            'timeout_budget_ms': 8000, 'timeout_lateness_ms': 0}


def frame_window():
    return {'window_id': '00000000-0000-4000-8000-000000000004',
            'window_start': '2026-09-25T18:00:00Z',
            'window_end': '2026-09-25T18:00:01Z', 'active_tab': 'messages',
            'budget_us': 16667, 'frame_count': 10, 'slow_frame_count': 2,
            'slow_build_count': 2, 'slow_raster_count': 1,
            'max_build_us': 29000, 'max_raster_us': 19000}


def diagnostic_loss():
    return {'sample_id': '00000000-0000-4000-8000-000000000005',
            'dropped_events': 1, 'dropped_operations': 0, 'dropped_frames': 0}


def test_mixed_network_request_keeps_only_network_summary_and_shared_budget():
    data = envelope()
    data['network_requests'] = [request_failure()]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert result['metadata']['rejected_lines'] == 0
    assert request_failure()['request_id'] not in json.dumps(result)
    data['events'] = [
        {'operation_id': '00000000-0000-4000-8000-000000000002',
         'stage': 'matrixSend', 'error': 'timeout', 'elapsed_ms': 10, 'count': 1}
    ] * 20
    assert module().sanitize_logs([json.dumps(data)])['metadata']['rejected_lines'] == 1


def test_new_closed_loss_and_frame_windows_are_discarded_without_leakage():
    data = envelope()
    data['diagnostic_loss'] = diagnostic_loss()
    data['frame_windows'] = [frame_window()]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert result['metadata']['rejected_lines'] == 0
    assert frame_window()['window_id'] not in json.dumps(result)
    assert diagnostic_loss()['sample_id'] not in json.dumps(result)


@pytest.mark.parametrize('stage', ['matrix_sync_soft_kick', 'matrix_sync_hard_restart'])
def test_new_watchdog_stage_does_not_hide_network_summary(stage):
    data = envelope()
    data['events'] = [{'operation_id': '00000000-0000-4000-8000-000000000009',
                       'stage': stage, 'error': 'timeout',
                       'elapsed_ms': 45000, 'count': 1}]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert result['metadata']['rejected_lines'] == 0


def test_new_watchdog_stage_rejects_impossible_outcome():
    data = envelope()
    data['events'] = [{'operation_id': '00000000-0000-4000-8000-000000000009',
                       'stage': 'matrix_sync_soft_kick', 'error': 'cancelled',
                       'elapsed_ms': 100, 'count': 1}]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1


@pytest.mark.parametrize('mutate', [
    lambda data: data.update(diagnostic_loss={**diagnostic_loss(),
                                               'dropped_events': 0}),
    lambda data: data.update(diagnostic_loss={**diagnostic_loss(),
                                               'private': 'PRIVATE_SENTINEL'}),
    lambda data: data.update(diagnostic_loss={'dropped_events': 1,
                                               'dropped_operations': 0,
                                               'dropped_frames': 0}),
    lambda data: data.update(diagnostic_loss={**diagnostic_loss(),
                                               'sample_id': 'private-id'}),
    lambda data: data.update(frame_windows=[{**frame_window(),
                                              'private': 'PRIVATE_SENTINEL'}]),
    lambda data: data.update(frame_windows=[{**frame_window(),
                                              'slow_frame_count': 0}]),
    lambda data: data.update(frame_windows=[frame_window()] * 9),
])
def test_invalid_discarded_failure_extensions_reject_entire_batch(mutate):
    data = envelope()
    mutate(data)
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


@pytest.mark.parametrize('omit_events', [False, True])
def test_mixed_operations_export_only_independently_validated_networks(omit_events):
    data = envelope()
    data['operations'] = [operation()]
    if omit_events:
        del data['events']  # Live receiver omits unset default events in stdout.
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert result['metadata']['exported_samples'] == 1
    assert result['metadata']['rejected_lines'] == 0
    assert '00000000-0000-4000-8000-000000000002' not in json.dumps(result)


def test_networks_only_with_unset_default_events_is_supported_but_explicit_null_rejected():
    data = envelope()
    del data['events']
    assert module().sanitize_logs([json.dumps(data)])['metadata']['exported_samples'] == 1
    data['events'] = None
    assert module().sanitize_logs([json.dumps(data)])['metadata']['rejected_lines'] == 1


def test_discarded_operations_are_not_a_trusted_or_exported_performance_schema():
    data = envelope()
    data['operations'] = [{'token': 'PRIVATE_SENTINEL', 'raw_exception': 'PRIVATE_SENTINEL',
                           'account_id': 'PRIVATE_SENTINEL', 'nested': {'body': 'PRIVATE_SENTINEL'}}]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)
    assert any('not revalidated' in note and 'performance' in note for note in result['metadata']['coverage'])


@pytest.mark.parametrize('operations', [None, True, {}, 'PRIVATE_SENTINEL',
                                       [None], [True], ['PRIVATE_SENTINEL'], [[]],
                                       [operation()] * 21])
def test_invalid_discarded_operation_structure_or_count_rejects_batch(operations):
    data = envelope()
    data['operations'] = operations
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


def test_events_and_operations_share_twenty_record_budget():
    data = envelope()
    data['events'] = [{'operation_id': '00000000-0000-4000-8000-000000000002',
                       'stage': 'matrixSend', 'error': 'timeout', 'elapsed_ms': 10, 'count': 1}] * 10
    data['operations'] = [operation()] * 10
    result = module().sanitize_logs([json.dumps(data)])
    assert result['metadata']['exported_samples'] == 1
    data['operations'].append(operation())
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1


def test_operations_only_log_is_legacy_and_mixed_invalid_network_still_rejected():
    data = envelope()
    del data['events']
    del data['networks']
    data['operations'] = [operation()]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['legacy_lines'] == 1
    data['networks'] = [{**sample(), 'attempts': True, 'token': 'PRIVATE_SENTINEL'}]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


def test_discarded_operations_keep_line_and_export_caps_and_parser_errors_bounded(monkeypatch):
    data = envelope()
    data['operations'] = [{'ignored': 'PRIVATE_SENTINEL' * 6000}]
    result = module().sanitize_logs([json.dumps(data)])
    assert result['metadata']['oversized_lines'] == 1
    nested = '{"event":"client_diagnostics","operations":[' + '[' * 1200 + '0' + ']' * 1200 + ']}'
    tool = module()
    original_loads = json.loads
    def bounded_loads(value):
        if value == nested:
            raise RecursionError('PRIVATE_SENTINEL parser detail')
        return original_loads(value)
    monkeypatch.setattr(tool.json, 'loads', bounded_loads)
    result = tool.sanitize_logs([nested, json.dumps(envelope())])
    assert result['metadata']['rejected_lines'] == 1
    assert result['metadata']['exported_samples'] == 1
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


def test_preserves_original_summary_and_drops_legacy_fields():
    data = envelope()
    data.update(events=[{'operation_id': '00000000-0000-4000-8000-000000000002',
                        'stage': 'matrixSend', 'error': 'timeout', 'elapsed_ms': 10, 'count': 1}],
                frames={'frame_count': 10, 'slow_frame_count': 1,
                        'slow_build_count': 1, 'slow_raster_count': 0})
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert result['metadata']['exported_samples'] == 1
    assert result['metadata']['scanned_lines'] == 1
    assert '0.4.14' not in json.dumps(result['records'])


@pytest.mark.parametrize('change', [
    {'account_id': 'PRIVATE_SENTINEL'}, {'ip': 'PRIVATE_SENTINEL'},
    {'carrier': 'PRIVATE_SENTINEL'}, {'sample_id': 'PRIVATE_SENTINEL'},
    {'version': 'PRIVATE_SENTINEL'}, {'platform': 'PRIVATE_SENTINEL'},
    {'target': 'PRIVATE_SENTINEL'}, {'network': 'PRIVATE_SENTINEL'},
    {'window_start': '2026-09-25T18:00:00'}, {'window_end': '2026-09-25T18:01:00+08:00'},
    {'window_start': '2026-02-30T18:00:00Z'}, {'window_start': '2026-09-25T18:02:00Z'},
    {'attempts': True}, {'attempts': 0}, {'attempts': 1000001}, {'attempts': 3},
    {'http_2xx': '1'}, {'http_3xx': -1}, {'http_4xx': 1000001},
    {'network_errors': True}, {'success_latency_buckets': [1] * 8},
    {'success_latency_buckets': [1] * 9}, {'success_latency_buckets': [True] + [0] * 8},
])
def test_invalid_or_private_summary_is_never_exported(change):
    data = envelope()
    data['networks'][0].update(change)
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert result['metadata']['rejected_lines'] == 1
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


@pytest.mark.parametrize('mutate', [
    lambda data: data.update(token='PRIVATE_SENTINEL'),
    lambda data: data.update(platform='PRIVATE_SENTINEL'),
    lambda data: data.update(version='PRIVATE_SENTINEL'),
    lambda data: data.update(events=[{'body': 'PRIVATE_SENTINEL'}]),
    lambda data: data.update(frames={'body': 'PRIVATE_SENTINEL'}),
    lambda data: data.update(networks=data['networks'] * 2),
    lambda data: data.update(networks=[{**sample(), 'sample_id': '00000000-0000-4000-8000-00000000000' + str(i)} for i in range(9)]),
])
def test_private_envelope_or_invalid_batch_rejected(mutate):
    data = envelope()
    mutate(data)
    result = module().sanitize_logs([json.dumps(data)])
    assert result['records'] == []
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


def test_no_networks_is_empty_with_explicit_coverage_not_zero_failure_rate():
    data = envelope()
    del data['networks']
    result = module().sanitize_logs([json.dumps(data), 'PRIVATE_SENTINEL not json',
                                    json.dumps({'event': 'other', 'password': 'PRIVATE_SENTINEL'})])
    assert result['records'] == []
    assert result['metadata']['exported_samples'] == 0
    assert result['metadata']['legacy_lines'] == 1
    assert result['metadata']['measurement_status'] == 'no_valid_network_summaries'
    assert result['metadata']['log_retention_verified'] is False
    assert 'failure_rate' not in json.dumps(result)
    assert 'PRIVATE_SENTINEL' not in json.dumps(result)


def test_hard_limits_scanning_and_oversized_lines():
    tool = module()
    result = tool.sanitize_logs([json.dumps(envelope())] * 3, tail=2)
    assert result['metadata']['scanned_lines'] == 2
    assert result['metadata']['truncated'] is True
    assert len(result['records']) == 2  # Preserve IDs so network_report can deduplicate.
    assert tool.sanitize_logs(['x' * 65537])['metadata']['oversized_lines'] == 1
    for hours, tail in [(0, 1), (73, 1), (72, 100001), (72, 0), (True, 20000)]:
        with pytest.raises(ValueError):
            tool.collection_command(hours, tail)


def test_scanner_never_consumes_a_line_beyond_the_hard_limit():
    def lines():
        yield json.dumps(envelope())
        yield json.dumps(envelope())
        raise AssertionError('Scanner read beyond the authorized tail')

    result = module().sanitize_logs(lines(), tail=2)
    assert result['metadata']['scanned_lines'] == 2
    assert result['metadata']['truncated'] is True


@pytest.mark.parametrize('cap', ['bytes', 'samples'])
def test_export_memory_is_bounded_and_lost_coverage_is_explicit(cap):
    tool = module()
    if cap == 'bytes':
        tool.MAX_EXPORT_BYTES = 1
    else:
        tool.MAX_EXPORTED_SAMPLES = 1
    result = tool.sanitize_logs([json.dumps(envelope())] * 3)
    metadata = result['metadata']
    assert metadata['scanned_lines'] == 3
    assert metadata['dropped_batches'] == (3 if cap == 'bytes' else 2)
    assert metadata['exported_samples'] == (0 if cap == 'bytes' else 1)
    assert metadata['export_limit_reached'] is True
    assert metadata['truncated'] is True
    assert metadata['measurement_status'] == 'export_limited'
    assert metadata['exported_bytes'] <= tool.MAX_EXPORT_BYTES
    assert 'failure_rate' not in json.dumps(result)
    wire = '\n'.join(json.dumps(row) for row in result['records']) + '\n'
    wire += json.dumps({'collection_metadata': metadata})
    assert tool.decode_result(wire, 72, 20000) == (result['records'], metadata)


@pytest.mark.parametrize('change', [
    {'max_export_bytes': 999999999}, {'max_exported_samples': 1000000},
    {'dropped_batches': True}, {'dropped_batches': 1}, {'export_limit_reached': True},
    {'truncated': True}, {'exported_bytes': 1}, {'private_token': 'PRIVATE_SENTINEL'},
])
def test_metadata_cannot_hide_dropped_records_or_weaken_export_limits(change):
    tool = module()
    result = tool.sanitize_logs([json.dumps(envelope())])
    metadata = {**result['metadata'], **change}
    wire = json.dumps(result['records'][0]) + '\n' + json.dumps({'collection_metadata': metadata})
    with pytest.raises(ValueError):
        tool.decode_result(wire, 72, 20000)


def test_command_uses_only_existing_strict_jumper_wrapper_and_fixed_container():
    tool = module()
    command = tool.collection_command(72, 20000)
    assert command[:4] == ['pwsh.exe', '-NoProfile', '-File', str(ROOT / 'scripts/starchat-server.ps1')]
    assert command[4:6] == ['-Action', 'Command']
    assert command[6] == '-RemoteCommand'
    assert '--since' in tool.REMOTE_PROGRAM and '--tail' in tool.REMOTE_PROGRAM
    assert 'starchat-business-api-1' in tool.REMOTE_PROGRAM
    assert 'docker' in tool.REMOTE_PROGRAM and "'logs'" in tool.REMOTE_PROGRAM
    assert 'StrictHostKeyChecking=no' not in str(command)
    assert '--insecure' not in str(command) and '-Action Tunnel' not in str(command)
    wrapper = (ROOT / 'scripts/starchat-server.ps1').read_text(encoding='utf-8')
    assert 'StrictHostKeyChecking=yes' in wrapper and '-J jumper' in wrapper


def test_cli_writes_only_sanitized_jsonl_and_separate_metadata(tmp_path, capsys):
    tool = module()
    tool.ARTIFACTS = tmp_path
    result = tool.sanitize_logs([json.dumps(envelope())])
    wire = '\n'.join(json.dumps(row) for row in result['records']) + '\n'
    wire += json.dumps({'collection_metadata': result['metadata']}) + '\n'

    def runner(command, **kwargs):
        assert kwargs['check'] is False
        return subprocess.CompletedProcess(command, 0, wire, 'PRIVATE_SENTINEL')

    output = tmp_path / 'collection.jsonl'
    assert tool.main(['--output', str(output)], runner=runner) == 0
    assert json.loads(output.read_text(encoding='utf-8')) == result['records'][0]
    meta = json.loads(output.with_suffix('.meta.json').read_text(encoding='utf-8'))
    assert meta['exported_samples'] == 1
    assert meta['since_hours'] == 72 and meta['tail_limit'] == 20000
    assert 'PRIVATE_SENTINEL' not in capsys.readouterr().out


def test_cli_empty_log_output_is_empty_file_not_missing_result(tmp_path, capsys):
    tool = module()
    tool.ARTIFACTS = tmp_path
    metadata = tool.sanitize_logs([])['metadata']
    def runner(command, **kwargs):
        return subprocess.CompletedProcess(command, 0, json.dumps({'collection_metadata': metadata}), '')
    output = tmp_path / 'empty.jsonl'
    assert tool.main(['--output', str(output)], runner=runner) == 0
    assert output.read_bytes() == b''
    assert output.with_suffix('.meta.json').is_file()
    assert 'failure_rate' not in capsys.readouterr().out


@pytest.mark.parametrize('wire,code', [('PRIVATE_SENTINEL raw log', 0), ('', 0), ('PRIVATE_SENTINEL', 1)])
def test_cli_remote_failure_never_exposes_raw_stdout_stderr_or_writes_report(tmp_path, capsys, wire, code):
    tool = module()
    tool.ARTIFACTS = tmp_path
    def runner(command, **kwargs):
        return subprocess.CompletedProcess(command, code, wire, 'PRIVATE_SENTINEL')
    output = tmp_path / 'failed.jsonl'
    assert tool.main(['--output', str(output)], runner=runner) == 1
    assert not output.exists()
    captured = capsys.readouterr()
    assert 'PRIVATE_SENTINEL' not in captured.out + captured.err


def test_output_outside_artifacts_is_rejected_before_remote_request(tmp_path):
    tool = module()
    tool.ARTIFACTS = tmp_path / 'allowed'
    calls = []
    with pytest.raises(SystemExit):
        tool.main(['--output', str(tmp_path / 'escape.jsonl')], runner=lambda *a, **k: calls.append(a))
    assert calls == []


def test_metadata_symlink_cannot_escape_artifact_root(tmp_path):
    tool = module()
    artifacts = tmp_path / 'artifacts'
    artifacts.mkdir()
    tool.ARTIFACTS = artifacts
    secret = tmp_path / 'outside.json'
    secret.write_text('ORIGINAL', encoding='utf-8')
    metadata = artifacts / 'collection.meta.json'
    metadata.symlink_to(secret)
    calls = []
    with pytest.raises(SystemExit):
        tool.main(['--output', str(artifacts / 'collection.jsonl')], runner=lambda *a, **k: calls.append(a))
    assert calls == []
    assert secret.read_text(encoding='utf-8') == 'ORIGINAL'


def test_generated_remote_program_only_emits_sanitized_rows_and_counts(monkeypatch, capsys):
    tool = module()
    observed = []
    data = envelope()
    del data['events']
    data['operations'] = [{'token': 'PRIVATE_SENTINEL', 'body': 'PRIVATE_SENTINEL'}]
    data['network_requests'] = [request_failure()]
    data['diagnostic_loss'] = diagnostic_loss()
    data['frame_windows'] = [frame_window()]

    class Process:
        def __init__(self, command, **kwargs):
            observed.append((command, kwargs))
            self.stdout = io.BytesIO(('PRIVATE_SENTINEL raw log\n' + json.dumps(data) + '\n').encode('utf-8'))

        def poll(self):
            return 0

        def wait(self, **kwargs):
            return 0

    monkeypatch.setattr(subprocess, 'Popen', Process)
    monkeypatch.setattr(signal, 'SIGALRM', 14, raising=False)
    monkeypatch.setattr(signal, 'alarm', lambda *args: None, raising=False)
    monkeypatch.setattr(signal, 'signal', lambda *args: None)
    namespace = {}
    exec(tool.REMOTE_PROGRAM, namespace)
    assert namespace['_remote_main'](72, 20000) == 0
    assert observed[0][0] == ['docker', 'logs', '--since', '72h', '--tail', '20000', 'starchat-business-api-1']
    captured = capsys.readouterr()
    assert 'PRIVATE_SENTINEL' not in captured.out + captured.err
    rows, metadata = tool.decode_result(captured.out, 72, 20000)
    assert rows == [{'event': 'client_diagnostics', 'networks': [sample()]}]
    assert metadata['scanned_lines'] == 2


def test_remote_docker_error_is_fixed_and_never_exports_log_payload(monkeypatch, capsys):
    tool = module()

    class Process:
        def __init__(self, *args, **kwargs):
            self.stdout = io.BytesIO((json.dumps(envelope()) + '\nPRIVATE_SENTINEL\n').encode('utf-8'))

        def poll(self):
            return 1

        def wait(self, **kwargs):
            return 1

    monkeypatch.setattr(subprocess, 'Popen', Process)
    monkeypatch.setattr(signal, 'SIGALRM', 14, raising=False)
    monkeypatch.setattr(signal, 'alarm', lambda *args: None, raising=False)
    monkeypatch.setattr(signal, 'signal', lambda *args: None)
    namespace = {}
    exec(tool.REMOTE_PROGRAM, namespace)
    assert namespace['_remote_main'](72, 20000) == 1
    captured = capsys.readouterr()
    assert captured.out == ''
    assert captured.err == 'NETWORK_COLLECTION_REMOTE_FAILED\n'
