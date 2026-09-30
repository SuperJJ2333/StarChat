"""Summarize sanitized probes and immutable client network summaries, never rank regions."""
from __future__ import annotations

import argparse
import json
import math
import re
from collections import defaultdict
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOUNDS = [100, 250, 500, 1000, 2000, 5000, 10000, 30000]
OUTCOMES = ('http_2xx', 'http_3xx', 'http_4xx', 'http_5xx', 'network_errors', 'timeouts', 'cancelled')
NETWORKS = {'unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other'}
NETWORK_FIELDS = {'sample_id', 'version', 'platform', 'window_start', 'window_end',
                  'target', 'network', 'attempts', 'success_latency_buckets', *OUTCOMES}
PROBE_DIMENSIONS = ('target_id', 'route', 'vantage', 'country', 'carrier', 'network',
                    'dns_bypassed', 'proxy_mode', 'transparent_routing')


def utc(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)', value):
        raise ValueError('Invalid UTC time')
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def validate_network(row):
    if not isinstance(row, dict) or set(row) != NETWORK_FIELDS:
        raise ValueError('Invalid closed network summary')
    if (not isinstance(row['sample_id'], str) or not re.fullmatch(
            r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', row['sample_id'])
            or not isinstance(row['version'], str) or not re.fullmatch(r'\d{1,4}\.\d{1,4}\.\d{1,4}(?:\+\d{1,8})?', row['version'])
            or row['platform'] not in ('android', 'ios', 'other')
            or row['target'] != 'primary_api' or row['network'] not in NETWORKS):
        raise ValueError('Invalid network metadata')
    if utc(row['window_start']) > utc(row['window_end']):
        raise ValueError('Invalid time window')
    for field in ('attempts', *OUTCOMES):
        if type(row[field]) is not int or not 0 <= row[field] <= 1000000:
            raise ValueError('Invalid network counter')
    if row['attempts'] < 1 or sum(row[field] for field in OUTCOMES) != row['attempts']:
        raise ValueError('Inconsistent network denominator')
    buckets = row['success_latency_buckets']
    if (not isinstance(buckets, list) or len(buckets) != 9
            or any(type(value) is not int or not 0 <= value <= 1000000 for value in buckets)
            or sum(buckets) != row['http_2xx']):
        raise ValueError('Inconsistent success histogram')


def histogram_quantile(buckets, fraction):
    if not sum(buckets):
        return None, False
    rank = math.ceil(sum(buckets) * fraction)
    running = 0
    for index, count in enumerate(buckets):
        running += count
        if running >= rank:
            return (BOUNDS[index], False) if index < 8 else (None, True)
    raise ValueError('Invalid histogram')


def quantile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def build_report(rows):
    probes, groups = defaultdict(list), {}
    seen, duplicates, ignored = {}, 0, 0
    for envelope in rows:
        if not isinstance(envelope, dict):
            raise ValueError('Input records must be JSON objects')
        if envelope.get('record_type') == 'https_probe':
            row = envelope
            if type(row.get('success')) is not bool:
                raise ValueError('Probe success must be boolean')
            total = row.get('total_ms')
            if (isinstance(total, bool) or not isinstance(total, (int, float))
                    or not math.isfinite(total) or not 0 <= total <= 3600000):
                raise ValueError('Invalid probe timing')
            utc(row.get('started_at'))
            key = tuple(row.get(field, False if field == 'dns_bypassed' else 'unknown')
                        for field in PROBE_DIMENSIONS)
            if (type(key[6]) is not bool or any(not isinstance(value, str) or len(value) > 64
                                              for value in (*key[:6], *key[7:]))):
                raise ValueError('Invalid probe grouping metadata')
            identity = ('probe', row.get('sample_id'))
            if not isinstance(identity[1], str) or not 1 <= len(identity[1]) <= 64:
                raise ValueError('Invalid probe sample ID')
            canonical = json.dumps(row, sort_keys=True, separators=(',', ':'), allow_nan=False)
            if identity in seen:
                if seen[identity] != canonical:
                    raise ValueError('Sample ID conflict')
                duplicates += 1
                continue
            seen[identity] = canonical
            probes[key].append(row)
            continue
        networks = envelope.get('networks', [])
        if not isinstance(networks, list) or len(networks) > 8:
            raise ValueError('Invalid networks envelope')
        if not networks:
            ignored += 1
        for row in networks:
            validate_network(row)
            canonical = json.dumps(row, sort_keys=True, separators=(',', ':'), allow_nan=False)
            identity = ('user', row['sample_id'])
            if identity in seen:
                if seen[identity] != canonical:
                    raise ValueError('Sample ID conflict')
                duplicates += 1
                continue
            seen[identity] = canonical
            key = tuple(row[field] for field in ('version', 'platform', 'target', 'network'))
            group = groups.setdefault(key, {**dict(zip(('version', 'platform', 'target', 'network'), key)),
                                           'attempts': 0, **dict.fromkeys(OUTCOMES, 0),
                                           'success_latency_buckets': [0] * 9,
                                           'window_start': row['window_start'],
                                           'window_end': row['window_end'], 'samples': 0})
            for field in ('attempts', *OUTCOMES):
                group[field] += row[field]
            group['success_latency_buckets'] = [left + right for left, right in
                zip(group['success_latency_buckets'], row['success_latency_buckets'])]
            group['window_start'] = min(group['window_start'], row['window_start'], key=utc)
            group['window_end'] = max(group['window_end'], row['window_end'], key=utc)
            group['samples'] += 1
    user_output = []
    for key in sorted(groups):
        group = groups[key]
        attempts = group['attempts']
        group['network_failure_rate'] = (group['network_errors'] + group['timeouts']) / attempts
        group['http_response_rate'] = sum(group[field] for field in OUTCOMES[:4]) / attempts
        group['http_5xx_rate'] = group['http_5xx'] / attempts
        group['http_2xx_rate'] = group['http_2xx'] / attempts
        for name, fraction in (('p50', .5), ('p95', .95), ('p99', .99)):
            upper, overflow = histogram_quantile(group['success_latency_buckets'], fraction)
            group[f'{name}_success_ms_upper_bound'] = upper
            group[f'{name}_success_over_30000ms'] = overflow
        user_output.append(group)
    probe_output = []
    for key in sorted(probes):
        samples = probes[key]
        successes = [row['total_ms'] for row in samples if row['success']]
        phases = {}
        for phase in ('dns_ms', 'tcp_ms', 'tls_ms', 'ttfb_ms'):
            values = []
            for row in samples:
                value = row.get(phase)
                if value is None:
                    continue
                if (isinstance(value, bool) or not isinstance(value, (int, float))
                        or not math.isfinite(value) or not 0 <= value <= 3600000):
                    raise ValueError('Invalid probe phase timing')
                if row['success']:
                    values.append(value)
            phases[phase] = {'success_samples': len(values), 'p95_success_ms': quantile(values, .95)}
        probe_output.append({**dict(zip(PROBE_DIMENSIONS, key)),
                             'attempts': len(samples), 'successes': len(successes),
                             'failure_rate': (len(samples) - len(successes)) / len(samples),
                             'p50_success_total_ms': quantile(successes, .5),
                             'p95_success_total_ms': quantile(successes, .95),
                             'p99_success_total_ms': quantile(successes, .99), 'phases': phases})
    return {'schema_version': 1, 'decision': 'evidence_insufficient',
            'user_network_groups': user_output, 'probe_groups': probe_output,
            'duplicate_samples': duplicates, 'ignored_legacy_records': ignored,
            'success_latency_bucket_upper_bounds_ms': BOUNDS + [None],
            'limitations': ['Authenticated-scope, completed HTTP attempts only; not active-user counts',
                           'No measured geographic/carrier or HK/SG route attribution in user summaries',
                           'Queue loss, absent uploads and unconsumed responses are not observable here',
                           'HTTP probes do not establish message delivery, TURN quality or regional failover',
                           'Histogram quantiles are upper bounds; overflow has no finite upper bound',
                           'Require 7-14 days, peak/weekend coverage and comparable candidate stacks before choosing a primary']}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inputs', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(argv)
    root = (ROOT / 'docs/verification/artifacts').resolve()
    output = args.output.resolve()
    if not output.is_relative_to(root) or output == root:
        parser.error('Output must be below docs/verification/artifacts')
    records = []
    try:
        for path in args.inputs:
            with path.open(encoding='utf-8-sig') as stream:
                for line in stream:
                    if line.strip():
                        records.append(json.loads(line))
                    if len(records) > 100000:
                        raise ValueError('Input exceeds 100000 records')
        result = build_report(records)
    except (ValueError, TypeError, OSError, OverflowError):
        parser.error('Invalid, conflicting or oversized sanitized input; no report written')
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, ensure_ascii=True, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(output), 'decision': result['decision'],
                      'user_groups': len(result['user_network_groups']), 'probe_groups': len(result['probe_groups'])}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
