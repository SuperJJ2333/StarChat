"""Filter request facts remotely; raw access/application logs never leave host."""
from __future__ import annotations

import argparse
import ast
import base64
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
MAX_LINE_BYTES = 65536
MAX_RECORDS = 20000
MAX_EXPORT_BYTES = 16 * 1024 * 1024
ENVELOPE_KEYS = {'event', 'events', 'operations', 'frames', 'networks', 'network_requests'}
COVERAGE_COUNTS = {'scanned_lines', 'rejected_lines', 'rejected_records', 'ignored_legacy_lines',
                   'oversized_lines', 'exported_records'}
COVERAGE_FLAGS = {'export_limit_reached', 'truncated', 'log_retention_verified'}


def _models():
    service = str(ROOT / 'services' / 'business-api')
    if service not in sys.path:
        sys.path.insert(0, service)
    from app.core.network_request_timeline import (
        NetworkRequestDiagnostic, NetworkRequestTimeline, NetworkRequestTimelineDrops,
    )
    return NetworkRequestDiagnostic, NetworkRequestTimeline, NetworkRequestTimelineDrops


def sanitize_client(value):
    return _models()[0].model_validate(value).model_dump(exclude_none=True)


def sanitize_server(value):
    # Even a forged log with a syntactically valid real path cannot export it.
    safe = _models()[1].model_validate(value).model_dump(exclude_none=True)
    safe.pop('route_template')
    return safe


def sanitize_drop(value):
    return _models()[2].model_validate(value).model_dump(exclude_none=True)


def sanitize_export(value):
    keys = {'schema_version', 'clients', 'servers', 'drops', 'coverage', 'collected_at', 'measurement_status'}
    if (not isinstance(value, dict) or set(value) != keys
            or type(value['schema_version']) is not int or value['schema_version'] != 1):
        raise ValueError('Invalid closed export envelope')
    result = {'schema_version': 1}
    total = 0
    for key, validate in (('clients', sanitize_client), ('servers', sanitize_server), ('drops', sanitize_drop)):
        rows = value[key]
        if not isinstance(rows, list) or len(rows) > MAX_RECORDS:
            raise ValueError('Invalid bounded export list')
        total += len(rows)
        if total > MAX_RECORDS:
            raise ValueError('Too many exported records')
        result[key] = [validate({**row, 'route_template': '<unmatched>'}) if key == 'servers'
                       else validate(row) for row in rows]
    coverage = value['coverage']
    if not isinstance(coverage, dict) or set(coverage) != COVERAGE_COUNTS | COVERAGE_FLAGS:
        raise ValueError('Invalid closed coverage metadata')
    if (any(type(coverage[k]) is not int or not 0 <= coverage[k] <= 1000000 for k in COVERAGE_COUNTS)
            or any(type(coverage[k]) is not bool for k in COVERAGE_FLAGS)
            or coverage['exported_records'] != total):
        raise ValueError('Invalid coverage values')
    when = value['collected_at']
    if (not isinstance(when, str) or len(when) > 32
            or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|\+00:00)', when)):
        raise ValueError('Invalid collection UTC time')
    datetime.fromisoformat(when.replace('Z', '+00:00'))
    status = value['measurement_status']
    if status not in ('valid_request_metadata', 'no_new_request_evidence'):
        raise ValueError('Invalid measurement status')
    if (status == 'valid_request_metadata') != bool(total):
        raise ValueError('Inconsistent measurement status')
    return {**result, 'coverage': dict(coverage), 'collected_at': when, 'measurement_status': status}


def collect_records(lines, *, max_records=MAX_RECORDS, max_bytes=MAX_EXPORT_BYTES):
    if not 1 <= max_records <= MAX_RECORDS or not 1024 <= max_bytes <= MAX_EXPORT_BYTES:
        raise ValueError('Invalid bounded export settings')
    result = {'schema_version': 1, 'clients': [], 'servers': [], 'drops': []}
    coverage = dict(scanned_lines=0, rejected_lines=0, rejected_records=0,
                    ignored_legacy_lines=0, oversized_lines=0, exported_records=0,
                    export_limit_reached=False, truncated=False,
                    log_retention_verified=False)
    used_bytes = 0

    def append(kind, raw, validator):
        nonlocal used_bytes
        try:
            safe = validator(raw)
        except (ValueError, TypeError):
            coverage['rejected_records'] += 1
            return
        size = len(json.dumps(safe, separators=(',', ':'), ensure_ascii=True).encode('utf-8'))
        if coverage['exported_records'] >= max_records or used_bytes + size > max_bytes - 1024:
            coverage['export_limit_reached'] = coverage['truncated'] = True
            return
        result[kind].append(safe)
        used_bytes += size + 1  # include the list separator in the byte budget
        coverage['exported_records'] += 1

    for line in lines:
        coverage['scanned_lines'] += 1
        if isinstance(line, bytes):
            line = line.decode('utf-8', errors='replace')
        if not isinstance(line, str) or len(line.encode('utf-8')) > MAX_LINE_BYTES:
            coverage['oversized_lines'] += 1
            continue
        try:
            raw = json.loads(line)
        except (ValueError, TypeError):
            coverage['rejected_lines'] += 1
            continue
        if not isinstance(raw, dict):
            coverage['rejected_lines'] += 1
            continue
        event = raw.get('event')
        if event == 'client_diagnostics':
            rows = raw.get('network_requests')
            if rows is None:
                coverage['ignored_legacy_lines'] += 1
                continue
            events, operations = raw.get('events', []), raw.get('operations', [])
            if (set(raw) - ENVELOPE_KEYS or not isinstance(rows, list) or len(rows) > 8
                    or not isinstance(events, list) or not isinstance(operations, list)
                    or len(rows) + len(events) + len(operations) > 20):
                coverage['rejected_lines'] += 1
                continue
            for row in rows:
                append('clients', row, sanitize_client)
        elif event == 'server_request_timeline':
            append('servers', raw, sanitize_server)
        elif event == 'server_request_timeline_dropped':
            append('drops', raw, sanitize_drop)
        else:
            coverage['rejected_lines'] += 1
    result['coverage'] = coverage
    result['collected_at'] = datetime.now(timezone.utc).isoformat()
    result['measurement_status'] = ('valid_request_metadata' if coverage['exported_records']
                                    else 'no_new_request_evidence')
    return result


def _stdin_lines():
    # Bound parser allocations even for an arbitrary oversized raw log line.
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


def remote_command(container, *, since_hours, tail, max_records, max_bytes):
    if not re.fullmatch(r'starchat-[a-z0-9-]{1,80}', container):
        raise ValueError('Invalid container identifier')
    if not 1 <= since_hours <= 336 or not 1 <= tail <= 100000:
        raise ValueError('Invalid observation bounds')
    # Embed only repository source (no credentials/configuration/log input).
    # Embed the pure DTO declarations, not the logging worker implementation.
    text = (ROOT / 'services/business-api/app/core/network_request_timeline.py').read_text(encoding='utf-8-sig')
    names = {'REQUEST_ID_PATTERN', 'UTC_PATTERN', 'Methods', 'EndpointCategories',
             'Milliseconds', 'UtcTime', 'NetworkRequestDiagnostic', 'NetworkRequestTimeline',
             'NetworkRequestTimelineDrops'}
    declarations = []
    found = set()
    for node in ast.parse(text).body:
        node_names = ({node.name} if isinstance(node, ast.ClassDef) else
                      {target.id for target in node.targets if isinstance(target, ast.Name)}
                      if isinstance(node, ast.Assign) else set())
        if node_names & names:
            found |= node_names & names
            declarations.append(ast.get_source_segment(text, node))
    if found != names:
        raise ValueError('Closed DTO declarations changed; review filter inputs')
    model_source = ('from datetime import datetime\nfrom typing import Annotated, Literal\n'
                    'from pydantic import BaseModel, ConfigDict, Field, model_validator, field_validator\n'
                    + '\n\n'.join(declarations)).encode('utf-8')
    own_source = Path(__file__).read_bytes()
    bootstrap = (
        'import base64,sys,types;'
        'm=types.ModuleType("app.core.network_request_timeline");'
        'sys.modules[m.__name__]=m;'
        f'exec(compile(base64.b64decode({base64.b64encode(model_source).decode()!r}),"closed_models","exec"),m.__dict__);'
        f'sys.argv=["closed_filter","--filter","--max-records",{str(max_records)!r},"--max-bytes",{str(max_bytes)!r}];'
        f'exec(compile(base64.b64decode({base64.b64encode(own_source).decode()!r}),"closed_filter","exec"),'
        '{"__name__":"__main__","__file__":"/tmp/closed_filter.py"})'
    )
    pipeline = (f'docker logs --since {since_hours}h --tail {tail} {shlex.quote(container)} 2>&1 | '
                f'docker exec -i {shlex.quote(container)} python -c {shlex.quote(bootstrap)}')
    return 'bash -o pipefail -c ' + shlex.quote(pipeline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', action='store_true')
    parser.add_argument('--output')
    parser.add_argument('--container', default='starchat-business-api-1')
    parser.add_argument('--since-hours', type=int, default=24)
    parser.add_argument('--tail', type=int, default=100000)
    parser.add_argument('--max-records', type=int, default=MAX_RECORDS)
    parser.add_argument('--max-bytes', type=int, default=MAX_EXPORT_BYTES)
    args = parser.parse_args()
    if args.filter:
        result = collect_records(_stdin_lines(), max_records=args.max_records, max_bytes=args.max_bytes)
        print(json.dumps(result, separators=(',', ':')))
        return
    if not args.output:
        parser.error('--output below docs/verification/artifacts is required')
    output = Path(args.output).resolve()
    if not output.is_relative_to((ROOT / 'docs/verification/artifacts').resolve()):
        parser.error('Output must remain below verification artifacts')
    if not 1 <= args.max_records <= MAX_RECORDS or not 1024 <= args.max_bytes <= MAX_EXPORT_BYTES:
        parser.error('Invalid export bounds')
    command = remote_command(args.container, since_hours=args.since_hours, tail=args.tail,
                             max_records=args.max_records, max_bytes=args.max_bytes)
    completed = subprocess.run(
        ['pwsh.exe', '-NoProfile', '-File', str(ROOT / 'scripts/starchat-server.ps1'),
         '-Action', 'Command', '-RemoteCommand', command], capture_output=True, timeout=180,
    )
    if completed.returncode:
        raise SystemExit(f'Closed remote collection failed (exit {completed.returncode}); raw output not exported')
    if len(completed.stdout) > args.max_bytes + 2048:
        raise SystemExit('Closed export exceeds permitted size')
    try:
        result = json.loads(completed.stdout.decode('utf-8-sig'))
    except (ValueError, UnicodeError):
        raise SystemExit('Invalid closed export; raw output not exported') from None
    # Reconstruct the entire closed envelope before writing anything locally.
    try:
        result = sanitize_export(result)
    except (ValueError, TypeError):
        raise SystemExit('Invalid closed export; raw output not exported') from None
    result['coverage']['tail_limit'] = args.tail
    if result['coverage']['scanned_lines'] >= args.tail:
        result['coverage']['truncated'] = True
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(output), 'measurement_status': result['measurement_status'],
                      'coverage': result['coverage']}))


if __name__ == '__main__':
    main()
