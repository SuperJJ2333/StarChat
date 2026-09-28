"""Join single-request UUIDs; observations do not imply a physical root cause."""
from __future__ import annotations

import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path


def _validators():
    path = Path(__file__).with_name('collect_network_request_diagnostics.py')
    spec = importlib.util.spec_from_file_location('_closed_request_collector', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _index(rows, validate):
    unique, conflicts, duplicates, rejected = {}, set(), 0, 0
    if not isinstance(rows, list) or len(rows) > 20000:
        raise ValueError('Invalid bounded record list')
    for row in rows:
        try:
            safe = validate(row)
        except (ValueError, TypeError):
            rejected += 1
            continue
        key = safe['request_id']
        if key in unique:
            if safe == unique[key]:
                duplicates += 1
            else:
                conflicts.add(key)
        else:
            unique[key] = safe
    return unique, conflicts, duplicates, rejected


def build_report(collection):
    if (not isinstance(collection, dict) or type(collection.get('schema_version')) is not int
            or collection['schema_version'] != 1):
        raise ValueError('Invalid collection version')
    validators = _validators()
    groups = [collection.get(key, []) for key in ('clients', 'servers', 'drops')]
    if any(not isinstance(rows, list) for rows in groups) or sum(map(len, groups)) > 20000:
        raise ValueError('Combined record bound exceeded')
    clients, bad_client, duplicate_client, rejected_client = _index(
        collection.get('clients', []), validators.sanitize_client)
    servers, bad_server, duplicate_server, rejected_server = _index(
        collection.get('servers', []),
        lambda row: validators.sanitize_server({**row, 'route_template': '<unmatched>'}))
    conflicts = bad_client | bad_server
    counts, matches = Counter(), []
    for request_id in sorted((clients.keys() | servers.keys()) - conflicts):
        client, server = clients.get(request_id), servers.get(request_id)
        detail = {'request_id': request_id}
        if client is None:
            classification = 'server_only_no_client_failure_record'
        elif server is None:
            classification = 'client_only_unknown'
        elif server['termination'] != 'complete':
            classification = 'server_' + server['termination']
        elif client['reason'] == 'timeout':
            classification = 'client_timeout_server_complete'
            budget = client.get('timeout_budget_ms')
            if budget is not None and server['elapsed_ms'] > budget:
                counts['server_application_over_client_budget'] += 1
                detail['server_application_over_client_budget'] = True
        else:
            classification = 'client_failure_server_complete'
        counts[classification] += 1
        detail['observation'] = classification
        if client is not None:
            detail.update(client_reason=client['reason'], client_phase=client['phase'],
                          client_elapsed_ms=client['elapsed_ms'], version=client['version'],
                          platform=client['platform'])
        if server is not None:
            detail.update(server_elapsed_ms=server['elapsed_ms'],
                          server_termination=server['termination'])
        matches.append(detail)
    drop_max = dict.fromkeys(('queue_full', 'rate_limited', 'closed', 'sink_error'), 0)
    drops = collection.get('drops', [])
    if not isinstance(drops, list) or len(drops) > 20000:
        raise ValueError('Invalid bounded drop list')
    rejected_drops = 0
    for row in drops:
        try:
            safe = validators.sanitize_drop(row)
        except (ValueError, TypeError):
            rejected_drops += 1
            continue
        for key in drop_max:
            drop_max[key] = max(drop_max[key], safe[key])
    coverage = collection.get('coverage', {})
    if not isinstance(coverage, dict):
        raise ValueError('Invalid coverage')
    # Keep only fixed flags/counts; arbitrary imported text never enters a report.
    incomplete = (coverage.get('log_retention_verified') is not True
                  or coverage.get('truncated') is True or coverage.get('export_limit_reached') is True
                  or coverage.get('rejected_records', 0) != 0 or coverage.get('oversized_lines', 0) != 0
                  or any(drop_max.values()) or bool(conflicts)
                  or bool(rejected_client + rejected_server + rejected_drops))
    return dict(schema_version=1, causal_root_cause='not_established',
                counts=dict(counts), matches=matches,
                duplicate_client_records=duplicate_client, duplicate_server_records=duplicate_server,
                conflicting_request_ids=len(conflicts), rejected_client_records=rejected_client,
                rejected_server_records=rejected_server, rejected_drop_records=rejected_drops,
                observed_cumulative_drop_max=drop_max, coverage_incomplete=bool(incomplete),
                limitations=[
                    'Random IDs identify requests, never users or devices',
                    'Device/server wall clocks are not subtracted',
                    'ASGI send completion does not prove delivery to the client',
                    'Client-only records do not establish DNS, TCP or connectivity failure',
                    'Server-only records can be normal requests without a client failure',
                    'Cumulative drops across workers/restarts cannot be summed without scope identity',
                    'Application duration above client budget is an observation, not sole causation',
                    'Historical records without request IDs cannot be retroactively joined',
                ])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('collection')
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = Path(args.output).resolve()
    if not output.is_relative_to((root / 'docs/verification/artifacts').resolve()):
        parser.error('Output must remain below verification artifacts')
    source = Path(args.collection)
    if source.stat().st_size > 16 * 1024 * 1024 + 2048:
        raise SystemExit('Collection exceeds bound')
    result = build_report(json.loads(source.read_text(encoding='utf-8-sig')))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'counts': result['counts'], 'coverage_incomplete': result['coverage_incomplete']}))


if __name__ == '__main__':
    main()
