"""Summarize bounded client diagnostic logs locally without exporting raw records.

Usage: docker logs --tail 100000 starchat-business-api-1 2>&1 |
       python scripts/client_diagnostics_triage.py

Docker's JSON-file ``log`` envelopes and plain ``docker logs`` JSON lines are
accepted. Only closed aggregate labels and counts are printed. Run this on the
server; never copy input logs to a workstation for triage.
"""
from __future__ import annotations

import argparse
import ast
from collections import defaultdict
from datetime import datetime
import json
from pathlib import Path
import re
import sys

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator
from typing import Annotated, Literal


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SERVICE_ROOT = ROOT / 'services' / 'business-api'
MAX_LINE_BYTES = 65536
MAX_LINES = 100000
MAX_RECORDS = 20000
_DOCKER_TIME = re.compile(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,9})?(?:Z|\+00:00)$')
_IDENTITY_REF = re.compile(r'^[0-9a-f]{64}$')
_BATCH_KEYS = {'event', 'version', 'platform', 'events', 'frames', 'frame_windows',
               'diagnostic_loss', 'operations', 'networks', 'network_requests',
               'subject_ref', 'device_ref'}
_BATCH_MODELS = {}

_NETWORK_ASSIGNMENTS = {'REQUEST_ID_PATTERN', 'UTC_PATTERN', 'Methods',
                        'EndpointCategories', 'Milliseconds', 'UtcTime'}
_CLIENT_ASSIGNMENTS = {
    '_UUID_V4', '_UTC_TIME', 'OperationWire', 'PerformanceStageWire',
    'PerformanceResultWire', 'OpeningSourceWire', 'PerformanceLifecycleWire',
    'AppNetworkStateWire', 'MatrixStateWire', 'NetworkErrorWire',
    'EndpointCategoryWire', 'HttpMethodWire', 'CacheSourceWire',
    'MediaTypeWire', 'MediaPriorityWire', 'SizeBucketWire',
    'DatabaseOperationWire', 'RowCountBucketWire', 'RelayProtocolWire',
    '_PERFORMANCE_FRAME_FIELDS', '_SPAN_INDEX_SCHEMA',
    '_PERFORMANCE_FRAME_SCHEMA', 'NetworkCount', 'UtcWindow',
}
_CLIENT_CLASSES = {
    'DiagnosticEvent', 'DiagnosticFrames', 'DiagnosticLoss',
    'DiagnosticFrameWindow', 'PerformanceOperationStage',
    '_PerformanceMetadata', 'PerformanceOperation', 'PerformanceObservation',
    'DiagnosticNetwork', 'DiagnosticBatch',
}


def _trusted_service_root(value):
    try:
        path = Path(value)
        if not path.is_absolute():
            raise ValueError('Invalid service root')
        root = path.resolve(strict=True)
        for relative in ('app/api/client_diagnostics.py',
                         'app/core/network_request_timeline.py'):
            source = (root / relative).resolve(strict=True)
            if not source.is_relative_to(root) or not source.is_file():
                raise ValueError('Invalid service root')
        return root
    except (OSError, TypeError, ValueError):
        # Never include a supplied path in an error or aggregate export.
        raise ValueError('Invalid service root') from None


def _dto_declarations(path, assignments, classes, functions=frozenset()):
    """Compile only named DTO definitions from the trusted pinned release."""
    parsed = ast.parse(path.read_text(encoding='utf-8'), filename=str(path))
    selected, found = [], set()
    wanted = assignments | classes | functions
    for node in parsed.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
        elif isinstance(node, (ast.ClassDef, ast.FunctionDef)):
            name = node.name
        else:
            continue
        if name in wanted:
            selected.append(node)
            found.add(name)
    if found != wanted:
        raise ValueError('Closed diagnostics DTO unavailable')
    return compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec',
                   dont_inherit=True)


def _batch_model(service_root):
    """Use the receiver's exact DTO without loading auth/router modules."""
    root = _trusted_service_root(service_root)
    if root in _BATCH_MODELS:
        return _BATCH_MODELS[root]
    network_path = root / 'app' / 'core' / 'network_request_timeline.py'
    client_path = root / 'app' / 'api' / 'client_diagnostics.py'
    namespace = {
        '__name__': '_client_diagnostics_triage_dto',
        'Annotated': Annotated, 'Literal': Literal, 'datetime': datetime,
        'BaseModel': BaseModel, 'ConfigDict': ConfigDict, 'Field': Field,
        'model_validator': model_validator,
    }
    exec(_dto_declarations(network_path, _NETWORK_ASSIGNMENTS,
                           {'NetworkRequestDiagnostic'}), namespace)
    exec(_dto_declarations(client_path, _CLIENT_ASSIGNMENTS, _CLIENT_CLASSES,
                           {'_validate_stages'}), namespace)
    model = namespace['DiagnosticBatch']
    if not issubclass(model, BaseModel):
        raise RuntimeError('Closed diagnostics DTO unavailable')
    _BATCH_MODELS[root] = model
    return model


def _json_record(line):
    if isinstance(line, bytes):
        line = line.decode('utf-8')
    if not isinstance(line, str):
        raise ValueError('Invalid diagnostic line')
    raw = json.loads(line)
    if not isinstance(raw, dict):
        raise ValueError('Invalid diagnostic line')
    if set(raw) == {'log', 'stream', 'time'}:
        raw = json.loads(_docker_log_payload(raw))
    if not isinstance(raw, dict):
        raise ValueError('Invalid diagnostic batch')
    return raw


def _docker_log_payload(raw):
    when = raw['time']
    if (raw['stream'] != 'stdout' or not isinstance(when, str)
            or len(when) > 40 or not _DOCKER_TIME.fullmatch(when)
            or not isinstance(raw['log'], str)
            or len(raw['log'].encode('utf-8')) > MAX_LINE_BYTES):
        raise ValueError('Invalid Docker log envelope')
    datetime.fromisoformat(when.replace('Z', '+00:00'))
    return raw['log']


def _complete_diagnostic_prefix(line):
    """Recover only a complete first JSON object; never interpret its suffix."""
    if isinstance(line, bytes):
        line = line.decode('utf-8')
    try:
        outer = json.loads(line)
    except ValueError:
        payload = line
    else:
        if not isinstance(outer, dict) or set(outer) != {'log', 'stream', 'time'}:
            return None
        payload = _docker_log_payload(outer)
    payload = payload.lstrip()
    try:
        candidate, end = json.JSONDecoder().raw_decode(payload)
    except ValueError:
        return None
    if (not payload[end:].strip() or not isinstance(candidate, dict)
            or candidate.get('event') != 'client_diagnostics'):
        return None
    return candidate


def _identity_payload(version, platform, model):
    return (version, platform, json.dumps(model.model_dump(mode='json', exclude_none=True),
                                          sort_keys=True, separators=(',', ':')))


def _event_fingerprint(version, platform, item):
    """Detect indistinguishable samples carrying different random UUIDs."""
    metadata = item.model_dump(mode='json', exclude_none=True)
    metadata.pop('operation_id')
    return (version, platform, json.dumps(metadata, sort_keys=True, separators=(',', ':')))


def _retain(seen, identity, payload, duplicate_key, conflict_key, coverage, limit,
            *, ambiguous_on_repeat=False):
    if identity in seen:
        if ambiguous_on_repeat:
            # An unindexed correlation ID may name multiple legitimate spans,
            # even if both payloads happen to be byte-for-byte equal.
            coverage['identity_ambiguous'] = coverage['coverage_incomplete'] = True
        previous = seen[identity]
        if previous is None:
            return  # Previously quarantined identity remains excluded.
        if previous != payload:
            # Quarantine the first observation as well as this one. Do not let
            # one client-controlled collision invalidate the entire report.
            seen[identity] = None
            coverage[conflict_key] += 1
            coverage['coverage_incomplete'] = True
            return
        coverage[duplicate_key] += 1
        return
    if limit['count'] >= limit['max']:
        coverage['truncated'] = coverage['coverage_incomplete'] = True
        return
    seen[identity] = payload
    limit['count'] += 1


def summarize_logs(lines, *, max_lines=MAX_LINES, max_records=MAX_RECORDS,
                   service_root=DEFAULT_SERVICE_ROOT):
    """Return aggregates only; conflicted retry identities fail closed."""
    if (type(max_lines) is not int or not 1 <= max_lines <= MAX_LINES
            or type(max_records) is not int or not 1 <= max_records <= MAX_RECORDS):
        raise ValueError('Invalid triage bounds')
    coverage = dict(scanned_lines=0, accepted_batches=0, rejected_lines=0,
                    contaminated_lines=0, unparsed_suffix_lines=0,
                    ignored_lines=0, oversized_lines=0, duplicate_events=0,
                    duplicate_operations=0,
                    duplicate_frame_windows=0, duplicate_loss_samples=0,
                    conflicting_events=0, conflicting_operations=0,
                    conflicting_frame_windows=0,
                    conflicting_loss_samples=0, ignored_nonfinal_operations=0,
                    identity_ambiguous=False, event_identity_ambiguous=False,
                    coverage_incomplete=False,
                    event_count_semantics='accepted_distinct_ids_and_reported_count_not_unique_incidents',
                    operation_count_semantics='accepted_span_lower_bound', truncated=False)
    events, operations, windows, losses = {}, {}, {}, {}
    event_fingerprints = {}
    limit = {'count': 0, 'max': max_records}
    model_type = _batch_model(service_root)
    for index, line in enumerate(lines):
        if index >= max_lines:
            coverage['truncated'] = coverage['coverage_incomplete'] = True
            break
        coverage['scanned_lines'] += 1
        contaminated = False
        try:
            if not isinstance(line, (bytes, str)) or len(line.encode('utf-8') if isinstance(line, str) else line) > MAX_LINE_BYTES:
                coverage['oversized_lines'] += 1
                coverage['coverage_incomplete'] = True
                continue
            raw = _json_record(line)
        except (ValueError, TypeError, UnicodeError, OverflowError):
            try:
                raw = _complete_diagnostic_prefix(line)
            except (ValueError, TypeError, UnicodeError, OverflowError):
                raw = None
            if raw is None:
                marker = b'client_diagnostics' if isinstance(line, bytes) else 'client_diagnostics'
                if marker in line:
                    coverage['rejected_lines'] += 1
                    coverage['coverage_incomplete'] = True
                else:
                    coverage['ignored_lines'] += 1
                continue
            contaminated = True
        if raw.get('event') != 'client_diagnostics':
            coverage['ignored_lines'] += 1
            continue
        try:
            if set(raw) - _BATCH_KEYS:
                raise ValueError('Invalid batch fields')
            for key in ('subject_ref', 'device_ref'):
                if key in raw and (not isinstance(raw[key], str)
                                   or not _IDENTITY_REF.fullmatch(raw[key])):
                    raise ValueError('Invalid diagnostic reference')
            batch = model_type.model_validate({key: value for key, value in raw.items()
                                               if key not in ('event', 'subject_ref', 'device_ref')})
        except (ValueError, TypeError, UnicodeError, ValidationError, OverflowError):
            coverage['rejected_lines'] += 1
            coverage['coverage_incomplete'] = True
            continue
        coverage['accepted_batches'] += 1
        if contaminated:
            # The verified prefix is useful; the suffix could hide another
            # diagnostic batch. Keep the line rejected for coverage accounting.
            coverage['rejected_lines'] += 1
            coverage['contaminated_lines'] += 1
            coverage['unparsed_suffix_lines'] += 1
            coverage['coverage_incomplete'] = True
        version, platform = batch.version, batch.platform
        for item in batch.events:
            existed = item.operation_id in events
            old_conflicts = coverage['conflicting_events']
            _retain(events, item.operation_id, _identity_payload(version, platform, item),
                    'duplicate_events', 'conflicting_events', coverage, limit)
            if coverage['conflicting_events'] > old_conflicts:
                coverage['event_identity_ambiguous'] = True
            if not existed and item.operation_id in events:
                fingerprint = _event_fingerprint(version, platform, item)
                other_id = event_fingerprints.setdefault(fingerprint, item.operation_id)
                if other_id != item.operation_id:
                    # Equal metadata with two random IDs could be two genuine
                    # incidents or a retry that regenerated its ID.
                    coverage['event_identity_ambiguous'] = coverage['coverage_incomplete'] = True
        for item in batch.operations:
            if item.observation_kind != 'final':
                coverage['ignored_nonfinal_operations'] += 1
                continue
            operation_key = (item.operation_id, item.operation,
                             item.attempt_index, item.window_index)
            _retain(operations, operation_key, _identity_payload(version, platform, item),
                    'duplicate_operations', 'conflicting_operations', coverage, limit,
                    ambiguous_on_repeat=(item.attempt_index is None and item.window_index is None))
        for item in batch.frame_windows or []:
            _retain(windows, item.window_id, _identity_payload(version, platform, item),
                    'duplicate_frame_windows', 'conflicting_frame_windows', coverage, limit)
        if batch.diagnostic_loss is not None:
            item = batch.diagnostic_loss
            _retain(losses, item.sample_id, _identity_payload(version, platform, item),
                    'duplicate_loss_samples', 'conflicting_loss_samples', coverage, limit)
            coverage['coverage_incomplete'] = True  # Client reported local loss.

    grouped = defaultdict(lambda: {
        'events': defaultdict(lambda: [0, 0]),
        'operations': defaultdict(int), 'frame_windows': defaultdict(lambda: [0, 0, 0, 0, 0]),
        'diagnostic_loss': [0, 0, 0, 0],
    })
    for version, platform, encoded in (value for value in events.values() if value is not None):
        row = json.loads(encoded)
        counts = grouped[(version, platform)]['events'][(row['stage'], row['error'])]
        counts[0] += 1
        counts[1] += row['count']
    for version, platform, encoded in (value for value in operations.values() if value is not None):
        row = json.loads(encoded)
        stages = row['stages']
        last_stage = stages[-1]['stage'] if stages else 'unknown'
        key = (row['operation'], row['result'], row.get('network_error') or 'unknown', last_stage)
        grouped[(version, platform)]['operations'][key] += 1
    for version, platform, encoded in (value for value in windows.values() if value is not None):
        row = json.loads(encoded)
        count = grouped[(version, platform)]['frame_windows'][row['active_tab']]
        for i, value in enumerate((1, row['frame_count'], row['slow_frame_count'],
                                   row['slow_build_count'], row['slow_raster_count'])):
            count[i] += value
    for version, platform, encoded in (value for value in losses.values() if value is not None):
        row = json.loads(encoded)
        count = grouped[(version, platform)]['diagnostic_loss']
        for i, value in enumerate((1, row['dropped_events'], row['dropped_operations'],
                                   row['dropped_frames'])):
            count[i] += value

    by_client = []
    for (version, platform), group in sorted(grouped.items()):
        event_rows = [dict(stage=stage, error=error,
                           sample_count=counts[0], reported_count=counts[1])
                      for (stage, error), counts in sorted(group['events'].items())]
        op_rows = [dict(operation=op, result=result, network_error=error,
                        last_stage=stage, count=count)
                   for (op, result, error, stage), count in sorted(group['operations'].items())]
        frame_rows = [dict(active_tab=tab, window_count=counts[0], frame_count=counts[1],
                           slow_frame_count=counts[2], slow_build_count=counts[3],
                           slow_raster_count=counts[4], slow_ratio=round(counts[2] / counts[1], 4))
                      for tab, counts in sorted(group['frame_windows'].items())]
        loss = group['diagnostic_loss']
        by_client.append(dict(version=version, platform=platform, events=event_rows,
                              operations=op_rows,
                              frame_windows=frame_rows,
                              diagnostic_loss=dict(sample_count=loss[0], dropped_events=loss[1],
                                                   dropped_operations=loss[2], dropped_frames=loss[3])))
    return {'schema_version': 1, 'by_client': by_client, 'coverage': coverage}


def _stdin_lines():
    """Read at most one physical line into memory, even with hostile input."""
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
        if not line:
            return
        if len(line) > MAX_LINE_BYTES and not line.endswith(b'\n'):
            while line and not line.endswith(b'\n'):
                line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
            yield b' ' * (MAX_LINE_BYTES + 1)
        else:
            yield line


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-lines', type=int, default=MAX_LINES)
    parser.add_argument('--max-records', type=int, default=MAX_RECORDS)
    parser.add_argument('--service-root', default=str(DEFAULT_SERVICE_ROOT))
    args = parser.parse_args()
    result = summarize_logs(_stdin_lines(), max_lines=args.max_lines,
                            max_records=args.max_records, service_root=args.service_root)
    print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
