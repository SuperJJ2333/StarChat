import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def module():
    path = ROOT / 'scripts/network_report.py'
    assert path.is_file(), 'Network report is not implemented'
    spec = importlib.util.spec_from_file_location('network_report_tested', path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def sample(sample_id='00000000-0000-4000-8000-000000000001'):
    return dict(sample_id=sample_id, version='0.4.14+2181', platform='android',
                target='primary_api', network='wifi',
                window_start='2026-09-26T14:00:00Z', window_end='2026-09-26T14:01:00Z',
                attempts=5, http_2xx=2, http_3xx=0, http_4xx=1, http_5xx=0,
                network_errors=1, timeouts=1, cancelled=0,
                success_latency_buckets=[0, 1, 1, 0, 0, 0, 0, 0, 0])


def test_network_dedup_denominator_and_histogram_upper_bounds():
    row = {'event': 'client_diagnostics', 'networks': [sample()]}
    result = module().build_report([row, row])
    group = result['user_network_groups'][0]
    assert group['attempts'] == 5
    assert group['http_4xx'] == 1
    assert group['network_failure_rate'] == pytest.approx(.4)
    assert group['http_response_rate'] == pytest.approx(.6)
    assert group['p95_success_ms_upper_bound'] == 500
    assert result['duplicate_samples'] == 1
    assert result['decision'] == 'evidence_insufficient'


def test_conflicting_same_id_is_rejected():
    changed = sample()
    changed['network'] = 'mobile'
    with pytest.raises(ValueError, match='conflict'):
        module().build_report([{'networks': [sample(), changed]}])


@pytest.mark.parametrize('field,value', [('attempts', True), ('attempts', 6),
                                       ('success_latency_buckets', [2])])
def test_inconsistent_network_summary_is_rejected(field, value):
    invalid = sample()
    invalid[field] = value
    with pytest.raises(ValueError):
        module().build_report([{'networks': [invalid]}])


def test_failed_probe_counted_but_not_in_success_percentile():
    rows = [dict(record_type='https_probe', sample_id=str(index), target_id='hk',
                 route='origin', vantage='workstation', country='unknown',
                 carrier='unknown', network='unknown', success=success,
                 started_at='2026-09-26T14:00:00Z', total_ms=elapsed)
            for index, success, elapsed in [(1, True, 100), (2, True, 200), (3, False, 10000)]]
    group = module().build_report(rows)['probe_groups'][0]
    assert group['attempts'] == 3 and group['successes'] == 2
    assert group['failure_rate'] == pytest.approx(1 / 3)
    assert group['p95_success_total_ms'] == 200


def test_overflow_histogram_not_reported_as_30000ms():
    row = sample()
    row['success_latency_buckets'] = [0] * 8 + [2]
    group = module().build_report([{'networks': [row]}])['user_network_groups'][0]
    assert group['p95_success_ms_upper_bound'] is None
    assert group['p95_success_over_30000ms'] is True


def test_dns_bypass_and_path_trust_cannot_merge_with_normal_dns():
    normal = dict(record_type='https_probe', sample_id='normal', target_id='hk',
                  route='origin', vantage='workstation', country='unknown',
                  carrier='unknown', network='unknown', success=True,
                  started_at='2026-09-26T14:00:00Z', total_ms=100,
                  dns_bypassed=False, proxy_mode='disabled_environment',
                  transparent_routing='unverified')
    bypassed = {**normal, 'sample_id': 'override', 'dns_bypassed': True, 'total_ms': 5000}
    groups = module().build_report([normal, bypassed])['probe_groups']
    assert len(groups) == 2
    assert {item['dns_bypassed'] for item in groups} == {True, False}
    assert all(item['attempts'] == 1 for item in groups)
