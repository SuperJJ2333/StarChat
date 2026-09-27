import json
import importlib.util
from pathlib import Path
import shlex
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def client(**extra):
    return dict(request_id='12345678-1234-4234-9234-123456789abc', version='0.4.17+2186',
                platform='android', target='primary_api', network='wifi', method='GET',
                endpoint_category='profile', started_at='2026-09-27T06:00:00Z',
                elapsed_ms=8000, phase='awaiting_headers', reason='timeout',
                timeout_budget_ms=8000, timeout_lateness_ms=0, **extra)


def server(**extra):
    row = dict(event='server_request_timeline', request_id='12345678-1234-4234-9234-123456789abc',
               server_started_at='2026-09-27T18:00:00Z', elapsed_ms=700, method='GET',
               endpoint_category='profile', route_template='/api/v1/profile/{user_id}',
               termination='complete', http_status=200, headers_prepared_ms=600,
               body_prepared_ms=650, send_finished_ms=700)
    row.update(extra)
    return row


def test_collector_accepts_fixed_records_but_never_exports_paths_or_private_text():
    collector = load('collect_network_request_diagnostics')
    invalid = client(credential='secret-token', body='private-message')
    logs = [json.dumps({'event': 'client_diagnostics', 'network_requests': [client(), invalid]}),
            json.dumps(server()), 'raw access log with private-account and IP']
    result = collector.collect_records(logs)
    assert len(result['clients']) == 1
    assert len(result['servers']) == 1
    wire = json.dumps(result)
    for secret in ('secret-token', 'private-message', 'private-account', 'route_template', 'user_id'):
        assert secret not in wire
    assert result['coverage']['rejected_records'] >= 1
    assert result['coverage']['log_retention_verified'] is False


@pytest.mark.parametrize('field,value', [('request_id', 'account-name'), ('elapsed_ms', True),
                                      ('reason', 'DNS error for alice@example.com'),
                                      ('started_at', '2026-02-30T00:00:00Z'),
                                      ('phase', 'secret-url'), ('endpoint_category', 'alice')])
def test_invalid_client_values_are_rejected(field, value):
    collector = load('collect_network_request_diagnostics')
    row = client()
    row[field] = value
    result = collector.collect_records([json.dumps({'event': 'client_diagnostics', 'network_requests': [row]})])
    assert result['clients'] == []
    assert result['coverage']['rejected_records'] == 1


def test_export_bound_marks_coverage_instead_of_claiming_no_more_failures():
    collector = load('collect_network_request_diagnostics')
    result = collector.collect_records([json.dumps(server()), json.dumps(server())], max_records=1)
    assert len(result['servers']) == 1
    assert result['coverage']['export_limit_reached'] is True
    assert result['coverage']['truncated'] is True


def test_join_uses_uuid_and_never_subtracts_unsynchronised_wall_clocks():
    reporter = load('network_request_report')
    row = server()
    row.pop('route_template')
    result = reporter.build_report({'schema_version': 1, 'clients': [client()], 'servers': [row],
                                    'drops': [], 'coverage': {'log_retention_verified': False}})
    assert result['counts']['client_timeout_server_complete'] == 1
    assert result['matches'][0]['server_elapsed_ms'] == 700
    assert result['matches'][0]['client_elapsed_ms'] == 8000
    assert 'cross_host_latency_ms' not in json.dumps(result)
    assert result['causal_root_cause'] == 'not_established'


def test_absent_server_and_conflicting_duplicates_remain_unknown():
    reporter = load('network_request_report')
    first = client()
    conflict = {**first, 'elapsed_ms': 9000}
    result = reporter.build_report({'schema_version': 1, 'clients': [first, first, conflict],
                                    'servers': [], 'drops': [], 'coverage': {'truncated': True}})
    assert result['duplicate_client_records'] == 1
    assert result['conflicting_request_ids'] == 1
    assert result['counts'].get('client_only_unknown', 0) == 0
    assert result['coverage_incomplete'] is True


def test_server_over_budget_and_client_only_are_distinct_observations():
    reporter = load('network_request_report')
    slow = server(elapsed_ms=9000, send_finished_ms=9000)
    slow.pop('route_template')
    second = {**client(), 'request_id': '12345678-1234-4234-9234-123456789abd'}
    result = reporter.build_report({'schema_version': 1, 'clients': [client(), second],
                                    'servers': [slow], 'drops': [], 'coverage': {}})
    assert result['counts']['server_application_over_client_budget'] == 1
    assert result['counts']['client_only_unknown'] == 1
    assert 'network_disconnected' not in json.dumps(result)


def test_workstation_export_validation_rejects_extra_and_private_envelope_fields():
    collector = load('collect_network_request_diagnostics')
    clean = collector.collect_records([json.dumps(server())])
    assert collector.sanitize_export(clean)['servers'][0]['request_id'] == server()['request_id']
    with pytest.raises(ValueError):
        collector.sanitize_export({**clean, 'user': 'private-user'})
    with pytest.raises(ValueError):
        collector.sanitize_export({**clean, 'schema_version': True})
    with pytest.raises(ValueError):
        collector.sanitize_export({**clean, 'coverage': {**clean['coverage'], 'url': 'secret'}})


def test_remote_filter_bootstrap_really_runs_and_is_below_windows_command_bound():
    collector = load('collect_network_request_diagnostics')
    command = collector.remote_command('starchat-business-api-1', since_hours=24, tail=100000,
                                       max_records=20000, max_bytes=16777216)
    assert len(command) < 28000
    pipeline = shlex.split(command)[-1]
    bootstrap = shlex.split(pipeline.split(' | ', 1)[1])[-1]
    output = subprocess.run([sys.executable, '-c', bootstrap], input=json.dumps(server()) + '\n',
                            capture_output=True, text=True, timeout=10, check=False)
    assert output.returncode == 0, output.stderr
    result = json.loads(output.stdout)
    assert len(result['servers']) == 1
    assert 'route_template' not in output.stdout
    with pytest.raises(ValueError):
        collector.remote_command('api;cat-secret', since_hours=24, tail=100000,
                                  max_records=20000, max_bytes=16777216)


def test_report_combined_record_bound_applies_before_join():
    reporter = load('network_request_report')
    with pytest.raises(ValueError):
        reporter.build_report({'schema_version': 1, 'clients': [client()] * 10001,
                               'servers': [server()] * 10000, 'drops': [], 'coverage': {}})


@pytest.mark.parametrize('counter', ['rejected_records', 'oversized_lines'])
def test_report_collection_losses_mark_incomplete_even_when_retention_verified(counter):
    reporter = load('network_request_report')
    result = reporter.build_report({'schema_version': 1, 'clients': [], 'servers': [], 'drops': [],
                                    'coverage': {'log_retention_verified': True, counter: 1}})
    assert result['coverage_incomplete'] is True
