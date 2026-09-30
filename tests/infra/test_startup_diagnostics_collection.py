"""The local collector exports closed metadata, never arbitrary log content."""
import ast
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/collect_startup_diagnostics.py'


@pytest.fixture
def collector():
    if not SCRIPT.exists():
        pytest.skip('Collector behavior requires the missing executable')
    spec = importlib.util.spec_from_file_location('startup_collector', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_collector_executable_is_available():
    assert SCRIPT.exists(), 'Startup diagnostics collector is not implemented'


def report(**changes):
    row = {'type': 'startup_diagnostics', 'schema': 1, 'platform': 'ios',
           'event_id': '11111111-1111-4111-8111-111111111111',
           'occurred_at': '2026-09-27T06:08:00Z', 'app_version': '0.4.15',
           'build': 2170, 'os_version': '18.5', 'stage': 'matrix_preflight',
           'boundary': 'database_key', 'category': 'protected_data',
           'preflight_cause': 'missingKey', 'native_status': -25308,
           'login_stage': 'L04', 'count': 2}
    return row | changes


def test_mixed_envelopes_deduplicate_and_group_closed_metadata(collector):
    first = report()
    second = report(event_id='22222222-2222-4222-8222-222222222222', count=3)
    third = report(event_id='33333333-3333-4333-8333-333333333333',
                   app_version='0.4.16', build=2171, category='database',
                   native_status=None, login_stage='L07', boundary='account_storage')
    lines = [json.dumps(first), '2026-09-27T06:08:12Z ' + json.dumps(second),
             json.dumps({'message': json.dumps(third), 'source': '198.51.100.11'}),
             json.dumps({'log': json.dumps(first) + '\n', 'stream': 'stdout'})]
    result = collector.collect_logs(lines)
    assert result['metadata']['unique_events'] == 3
    assert result['metadata']['occurrence_count'] == 7
    assert result['metadata']['duplicate_lines'] == 1
    assert len(result['groups']) == 2
    assert result['groups'][0]['unique_events'] == 2
    assert result['groups'][0]['occurrence_count'] == 5
    assert '198.51.100.11' not in json.dumps(result)
    assert result['metadata']['measurement_status'] == 'validated_metadata_emissions'


@pytest.mark.parametrize('changes', [
    {'token': 'PRIVATE_TOKEN'}, {'account_id': 'PRIVATE_ACCOUNT'},
    {'category': 'PRIVATE_TEXT'}, {'native_status': 'PRIVATE_STATUS'},
    {'boundary': 'PRIVATE_BOUNDARY'}, {'login_stage': 'L09'},
    {'preflight_cause': 'PRIVATE_CAUSE'}, {'event_id': 'PRIVATE_ID'},
    {'app_version': '0.4.15 PRIVATE_VERSION'}, {'os_version': 'iPhone PRIVATE_OS'},
    {'count': True}, {'build': 1.0}, {'schema': True}, {'native_status': -25308.0},
    {'count': 101}, {'build': 10000001}, {'platform': 'android'},
    {'occurred_at': '2026-09-27T06:08:01Z'},
    {'occurred_at': '2026-02-30T06:08:00Z'},
])
def test_rejects_invalid_or_private_reports_without_echo(collector, changes):
    result = collector.collect_logs([json.dumps(report(**changes))])
    assert result['metadata']['rejected_lines'] == 1
    assert result['metadata']['unique_events'] == 0
    assert result['samples'] == []
    assert 'PRIVATE_' not in json.dumps(result)


NON_PLATFORM_CATEGORIES = ('metadata', 'database', 'filesystem', 'matrix_identity',
                           'matrix_credentials', 'matrix_rejected', 'matrix_rate_limited',
                           'matrix_service', 'network', 'unknown')
NATIVE_STATUSES = (-25308, -34018, -25291, -25300, -50, 'other')


@pytest.mark.parametrize('category', NON_PLATFORM_CATEGORIES)
@pytest.mark.parametrize('native_status', NATIVE_STATUSES)
def test_native_status_outside_platform_categories_is_rejected_without_export(
        collector, category, native_status):
    raw = 'PRIVATE_LOG_PREFIX ' + json.dumps(report(category=category, native_status=native_status))
    result = collector.collect_logs([raw])
    assert result['metadata']['rejected_lines'] == 1
    assert result['metadata']['unique_events'] == 0
    assert result['metadata']['occurrence_count'] == 0
    assert result['groups'] == []
    assert result['samples'] == []
    assert 'PRIVATE_LOG_PREFIX' not in json.dumps(result)


@pytest.mark.parametrize('category', ('platform', 'protected_data', 'keychain_permission')
                         + NON_PLATFORM_CATEGORIES)
@pytest.mark.parametrize('present', (True, False))
def test_null_or_absent_native_status_remains_valid_for_every_category(collector, category, present):
    row = report(category=category, native_status=None)
    if not present:
        del row['native_status']
    result = collector.collect_logs([json.dumps(row)])
    assert result['metadata']['unique_events'] == 1
    assert result['metadata']['rejected_lines'] == 0
    assert result['samples'][0]['native_status'] is None


def test_native_status_cross_field_rule_matches_executable_api_validator(collector):
    """Execute only the reviewed pure validator AST, without backend imports."""
    tree = ast.parse((ROOT / 'services/business-api/app/api/startup_diagnostics.py').read_text(encoding='utf-8'))
    model = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                 and node.name == 'StartupDiagnosticReport')
    validator = next(node for node in model.body if isinstance(node, ast.FunctionDef)
                     and node.name == 'native_status_requires_platform_category')
    assert any(isinstance(decorator, ast.Call) and isinstance(decorator.func, ast.Name)
               and decorator.func.id == 'model_validator'
               and any(keyword.arg == 'mode' and ast.literal_eval(keyword.value) == 'after'
                       for keyword in decorator.keywords)
               for decorator in validator.decorator_list)
    validator.decorator_list = []
    namespace = {}
    exec(compile(ast.Module(body=[validator], type_ignores=[]), '<safe-api-validator>', 'exec'), namespace)
    validate_api = namespace[validator.name]
    for category in collector.ENUMS['category']:
        for native_status in (*NATIVE_STATUSES, None):
            try:
                validate_api(SimpleNamespace(category=category, native_status=native_status))
                api_valid = True
            except ValueError:
                api_valid = False
            try:
                collector.validate_report(report(category=category, native_status=native_status))
                collector_valid = True
            except ValueError:
                collector_valid = False
            assert collector_valid == api_valid, (category, native_status)


def test_duplicate_json_keys_and_trailing_content_are_rejected(collector):
    duplicate = json.dumps(report()).replace('"count": 2', '"count": 2, "count": 3')
    result = collector.collect_logs([duplicate, json.dumps(report()) + ' PRIVATE_TOKEN'])
    assert result['metadata']['rejected_lines'] == 2
    assert 'PRIVATE_TOKEN' not in json.dumps(result)


def test_conflicting_retry_never_changes_first_frozen_body(collector):
    result = collector.collect_logs([json.dumps(report()), json.dumps(report(count=9))])
    assert result['metadata']['unique_events'] == 1
    assert result['metadata']['occurrence_count'] == 2
    assert result['metadata']['conflicting_duplicate_lines'] == 1
    assert result['samples'][0]['count'] == 2


def test_optional_fields_and_utc_minute_normalization(collector):
    row = report(occurred_at='2026-09-27T06:08:00+00:00', os_version='unknown')
    for key in ('preflight_cause', 'native_status', 'login_stage'):
        del row[key]
    result = collector.collect_logs([json.dumps(row)])
    sample = result['samples'][0]
    assert sample['occurred_at'] == '2026-09-27T06:08:00Z'
    assert sample['native_status'] is None
    assert result['groups'][0]['login_stage'] is None
    assert result['metadata']['collected_at'].endswith(':00Z')


def test_scan_event_and_sample_limits_are_explicit(collector):
    lines = [json.dumps(report(event_id=f'{number:08x}-1111-4111-8111-111111111111'))
             for number in range(1, 5)]
    result = collector.collect_logs(lines, max_lines=3, max_events=2, max_samples=1)
    assert result['metadata']['scanned_lines'] == 3
    assert result['metadata']['unique_events'] == 2
    assert result['metadata']['dropped_event_lines'] == 1
    assert result['metadata']['truncated'] is True
    assert len(result['samples']) == 1
    assert result['metadata']['samples_omitted'] == 1


def test_oversize_malformed_and_unrelated_lines_never_escape(collector):
    result = collector.collect_logs(['PRIVATE_TOKEN', 'x' * (collector.MAX_LINE_BYTES + 1),
                                     json.dumps({'type': 'unrelated', 'token': 'PRIVATE_TOKEN'})])
    assert result['metadata']['oversized_lines'] == 1
    assert result['metadata']['rejected_lines'] == 1
    assert result['metadata']['ignored_lines'] == 1
    assert 'PRIVATE_TOKEN' not in json.dumps(result)


def test_stream_drain_is_bounded_and_oversize_line_not_split_into_valid_events(collector):
    raw = b'x' * (collector.MAX_LINE_BYTES + 1) + json.dumps(report()).encode() + b'\n'
    raw += json.dumps(report()).encode() + b'\n'
    result = collector.collect_stream(io.BytesIO(raw), max_scan_bytes=len(raw))
    assert result['metadata']['unique_events'] == 1
    assert result['metadata']['oversized_lines'] == 1
    assert result['metadata']['scanned_bytes'] == len(raw)
    bounded = collector.collect_stream(io.BytesIO(raw), max_scan_bytes=100)
    assert bounded['metadata']['scanned_bytes'] == 100
    assert bounded['metadata']['truncated'] is True
    assert bounded['metadata']['unique_events'] == 0


@pytest.mark.parametrize('kwargs', [{'max_lines': True}, {'max_events': 10001},
                                    {'max_samples': 101}, {'max_scan_bytes': 0}])
def test_rejects_invalid_bounds(collector, kwargs):
    with pytest.raises(ValueError):
        collector.collect_logs([], **kwargs)


def test_schema_enums_and_constraints_match_api_without_importing_business_dependencies(collector):
    tree = ast.parse((ROOT / 'services/business-api/app/api/startup_diagnostics.py').read_text(encoding='utf-8'))
    constants = {node.targets[0].id: ast.literal_eval(node.value) for node in tree.body
                 if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
                 and isinstance(node.value, ast.Constant)}
    model = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                 and node.name == 'StartupDiagnosticReport')
    fields = {node.target.id: node for node in model.body if isinstance(node, ast.AnnAssign)}
    for field, expected in collector.ENUMS.items():
        annotation = fields[field].annotation
        literal = annotation.left if isinstance(annotation, ast.BinOp) else annotation
        values = literal.slice.elts if isinstance(literal.slice, ast.Tuple) else [literal.slice]
        assert set(map(ast.literal_eval, values)) == expected
    for field, pattern in collector.PATTERNS.items():
        declaration = fields[field].value
        value = next(keyword.value for keyword in declaration.keywords if keyword.arg == 'pattern')
        api_pattern = (ast.literal_eval(value) if isinstance(value, ast.Constant)
                       else constants[value.id])
        assert api_pattern == pattern
    assert set(fields) - {'schema_version', 'model_config'} | {'schema'} == collector.REPORT_FIELDS
    for field, bounds in {'build': (1, 10000000), 'count': (1, 100)}.items():
        keywords = {keyword.arg: ast.literal_eval(keyword.value) for keyword in fields[field].value.keywords}
        assert (keywords['ge'], keywords['le']) == bounds


def test_cli_reads_only_explicit_local_files_or_stdin_and_prints_generic_errors(collector, tmp_path, capsys):
    source = tmp_path / 'authorized.log'
    source.write_text(json.dumps(report()) + '\n', encoding='utf-8')
    assert collector.main(['--input', str(source)]) == 0
    assert json.loads(capsys.readouterr().out)['metadata']['unique_events'] == 1
    assert collector.main([], stdin=io.BytesIO(json.dumps(report()).encode())) == 0
    assert json.loads(capsys.readouterr().out)['metadata']['unique_events'] == 1
    assert collector.main(['--input', str(tmp_path / 'PRIVATE_TOKEN')]) == 1
    output = capsys.readouterr()
    assert output.out == ''
    assert output.err == 'STARTUP_COLLECTION_FAILED\n'


def test_runbook_has_operational_bounds_and_no_immediate_old_client_claim(collector):
    text = (ROOT / 'docs/runbooks/ios-startup-diagnostics.md').read_text(encoding='utf-8')
    for required in ('32KiB', '24h', '10000', '120', '10', '5 秒', '404', '0.4.7',
                     'cecd31ea-4450-454d-8b47-6b8d8bc57aed', '14:09', '14:08'):
        assert required in text
