"""Restricted exact-account diagnostic lookup; never exports handles or refs."""

from __future__ import annotations

import argparse
from bisect import bisect_right
from collections import Counter, deque
from datetime import datetime, timedelta, timezone
import getpass
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SERVICE_ROOT = ROOT / 'services' / 'business-api'
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(SERVICE_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVICE_ROOT))

from sqlalchemy import select, text

from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.diagnostic_identity import diagnostic_ref
from app.core.network_request_timeline import NetworkRequestTimeline
from app.modules.identity.models import User
from scripts import client_diagnostics_triage as triage


_REF = re.compile(r'^[0-9a-f]{64}$')
_MAX_TIMELINE_ROWS = 200


def resolve_refs(session, handle: str, current_key: bytes,
                 previous_key: bytes | None = None) -> tuple[str, ...]:
    """Resolve one current normalized handle to the immutable user ID."""
    if not isinstance(handle, str) or not 1 <= len(handle) <= 64:
        raise LookupError('Account not found')
    user_id = session.scalar(select(User.id).where(
        User.username_normalized == handle.casefold()))
    if user_id is None:
        raise LookupError('Account not found')
    keys = (current_key,) if previous_key is None else (current_key, previous_key)
    return tuple(diagnostic_ref(key, 'subject', str(user_id)) for key in keys)


def _docker_batch(line: str | bytes):
    if isinstance(line, bytes):
        line = line.decode('utf-8')
    if not isinstance(line, str) or len(line.encode('utf-8')) > triage.MAX_LINE_BYTES:
        raise ValueError('Invalid diagnostic line')
    outer = json.loads(line)
    if not isinstance(outer, dict) or set(outer) != {'log', 'stream', 'time'}:
        raise ValueError('Invalid Docker log envelope')
    when = outer['time']
    if (outer['stream'] != 'stdout' or not isinstance(when, str)
            or triage._DOCKER_TIME.fullmatch(when) is None
            or not isinstance(outer['log'], str)
            or len(outer['log'].encode('utf-8')) > triage.MAX_LINE_BYTES):
        raise ValueError('Invalid Docker log envelope')
    at = datetime.fromisoformat(when.replace('Z', '+00:00'))
    raw = json.loads(outer['log'])
    if not isinstance(raw, dict):
        raise ValueError('Invalid diagnostic batch')
    return at, raw


def summarize_account_logs(lines, *, refs: tuple[str, ...], since_hours: int,
                           now: datetime | None = None,
                           max_lines: int = triage.MAX_LINES,
                           max_records: int = triage.MAX_RECORDS):
    """Return only closed aggregates from bounded, retained Docker log lines."""
    if (type(since_hours) is not int or not 1 <= since_hours <= 168
            or type(max_lines) is not int or not 1 <= max_lines <= triage.MAX_LINES
            or type(max_records) is not int or not 1 <= max_records <= triage.MAX_RECORDS
            or not isinstance(refs, tuple) or not 1 <= len(refs) <= 2
            or any(not isinstance(ref, str) or _REF.fullmatch(ref) is None for ref in refs)):
        raise ValueError('Invalid private query bounds')
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or now.utcoffset() != timedelta(0):
        raise ValueError('Invalid UTC clock')
    cutoff = now - timedelta(hours=since_hours)
    earliest = latest = retained_first = retained_last = None
    scanned = rejected = matched = uncertain = considered = 0
    duplicate_operations = duplicate_requests = 0
    incomplete = False
    devices: dict[str, str] = {}
    operations: Counter[tuple[str, str, str, str, str]] = Counter()
    requests: Counter[tuple[str, str, str]] = Counter()
    seen_operations: dict[str, tuple[str, str, str, str, str]] = {}
    seen_requests: dict[str, tuple[str, str, str]] = {}
    operation_rows = []
    request_rows = []
    server_rows = deque(maxlen=max_records)
    model = triage._batch_model(triage.DEFAULT_SERVICE_ROOT)
    for line in lines:
        if scanned >= max_lines:
            incomplete = True
            break
        scanned += 1
        try:
            at, raw = _docker_batch(line)
        except (UnicodeError, ValueError, TypeError, OverflowError):
            rejected += 1
            incomplete = True
            continue
        retained_first = at if retained_first is None or at < retained_first else retained_first
        retained_last = at if retained_last is None or at > retained_last else retained_last
        if at < cutoff or at > now:
            continue
        if raw.get('event') == 'server_request_timeline':
            try:
                server = NetworkRequestTimeline.model_validate(raw)
            except (ValueError, TypeError, OverflowError):
                rejected += 1
                incomplete = True
                continue
            if len(server_rows) == max_records:
                incomplete = True
            server_rows.append(server)
            continue
        if raw.get('event') != 'client_diagnostics':
            continue
        if set(raw) - triage._BATCH_KEYS:
            rejected += 1
            incomplete = True
            continue
        subject = raw.get('subject_ref')
        device = raw.get('device_ref')
        if (not isinstance(subject, str) or _REF.fullmatch(subject) is None
                or (device is not None and (not isinstance(device, str)
                                            or _REF.fullmatch(device) is None))):
            rejected += 1
            incomplete = True
            continue
        if subject not in refs:
            continue
        try:
            batch = model.model_validate({key: value for key, value in raw.items()
                                          if key not in ('event', 'subject_ref', 'device_ref')})
        except (ValueError, TypeError, OverflowError):
            rejected += 1
            incomplete = True
            continue
        earliest = at if earliest is None or at < earliest else earliest
        latest = at if latest is None or at > latest else latest
        matched += 1
        label = devices.setdefault(device, f'device_{len(devices) + 1}') if device else 'device_unknown'
        for item in batch.operations or ():
            if considered >= max_records:
                incomplete = True
                break
            considered += 1
            if not hasattr(item, 'result'):
                continue
            stage = item.stages[-1].stage if item.stages else 'none'
            signature = (label, item.operation, item.result, stage,
                         item.network_error or 'none')
            previous = seen_operations.get(item.operation_id)
            if previous is not None:
                if previous != signature:
                    incomplete = True
                else:
                    duplicate_operations += 1
                continue
            seen_operations[item.operation_id] = signature
            if not (getattr(item, 'started_at_utc', None)
                    and getattr(item, 'ended_at_utc', None)
                    and getattr(item, 'time_anchor_age_ms', None) is not None):
                uncertain += 1
            operations[signature] += 1
            operation_rows.append((label, item, at, stage))
        for item in batch.network_requests or ():
            if considered >= max_records:
                incomplete = True
                break
            considered += 1
            signature = (label, item.phase, item.reason)
            previous = seen_requests.get(item.request_id)
            if previous is not None:
                if previous != signature:
                    incomplete = True
                else:
                    duplicate_requests += 1
                continue
            seen_requests[item.request_id] = signature
            requests[signature] += 1
            request_rows.append((label, item, at))

    request_items = {item.request_id: item for _, item, _ in request_rows}
    matched_servers = {}
    for server in server_rows:
        client = request_items.get(server.request_id)
        if (client is None or client.method != server.method
                or client.endpoint_category != server.endpoint_category):
            continue
        prior = matched_servers.setdefault(server.request_id, server)
        if prior != server:
            incomplete = True

    operation_requests = {}
    for _, item, _ in request_rows:
        if item.operation_id:
            operation_requests.setdefault(item.operation_id, set()).add(item.request_id)

    intervals = sorted((datetime.fromisoformat(row.server_started_at.replace('Z', '+00:00')),
                        datetime.fromisoformat(row.server_started_at.replace('Z', '+00:00'))
                        + timedelta(milliseconds=row.elapsed_ms))
                       for row in matched_servers.values())
    starts = [start for start, _ in intervals]
    latest_end = []
    for _, end in intervals:
        latest_end.append(max(end, latest_end[-1]) if latest_end else end)

    def overlaps(start_text, end_text, uncertainty_ms):
        start = datetime.fromisoformat(start_text.replace('Z', '+00:00'))
        end = datetime.fromisoformat(end_text.replace('Z', '+00:00'))
        left = start - timedelta(milliseconds=uncertainty_ms)
        right = end + timedelta(milliseconds=uncertainty_ms)
        index = bisect_right(starts, right)
        return index > 0 and latest_end[index - 1] >= left

    def utc(value):
        return value.isoformat(timespec='seconds').replace('+00:00', 'Z') if value else None

    timeline = []
    coincident = 0
    for label, item, observed, stage in operation_rows:
        started = getattr(item, 'started_at_utc', None)
        ended = getattr(item, 'ended_at_utc', None)
        direct = any(request_id in matched_servers for request_id in
                     operation_requests.get(item.operation_id, ()))
        if direct:
            correlation = 'request_uuid_match'
        elif started is None or ended is None:
            correlation = 'time_uncertain'
        elif overlaps(started, ended, item.clock_uncertainty_ms):
            correlation = 'coincident'
            coincident += 1
        else:
            correlation = 'none'
        timeline.append({
            'kind': 'operation', 'device': label, 'operation': item.operation,
            'result': item.result, 'last_stage': stage,
            'started_at_utc': started, 'ended_at_utc': ended,
            'observed_at_utc': utc(observed), 'correlation': correlation,
            'time_basis': 'calibrated_device' if started else 'upload_receipt',
        })
    for label, item, observed in request_rows:
        server = matched_servers.get(item.request_id)
        server_start = (datetime.fromisoformat(server.server_started_at.replace('Z', '+00:00'))
                        if server else None)
        timeline.append({
            'kind': 'network_request', 'device': label,
            'phase': item.phase, 'reason': item.reason,
            'endpoint_category': item.endpoint_category,
            'started_at_utc': server.server_started_at if server else None,
            'ended_at_utc': utc(server_start + timedelta(milliseconds=server.elapsed_ms))
            if server else None,
            'observed_at_utc': utc(observed),
            'correlation': 'request_uuid_match' if server else 'time_uncertain',
            'time_basis': 'server_request' if server else 'upload_receipt',
        })
    timeline.sort(key=lambda row: (
        datetime.fromisoformat((row['started_at_utc'] or row['observed_at_utc']).replace('Z', '+00:00')),
        row['device'], row['kind']))
    return {
        'scanned_lines': scanned,
        'rejected_lines': rejected,
        'matched_batches': matched,
        'coverage_first_utc': utc(earliest),
        'coverage_last_utc': utc(latest),
        'retained_first_utc': utc(retained_first),
        'retained_last_utc': utc(retained_last),
        'coverage_incomplete': incomplete or earliest is None
                               or retained_first is None or retained_first > cutoff,
        'time_uncertain_count': uncertain,
        'request_uuid_matches': len(matched_servers),
        'coincident_operations': coincident,
        'timeline_truncated': len(timeline) > _MAX_TIMELINE_ROWS,
        'device_timeline': timeline[-_MAX_TIMELINE_ROWS:],
        'duplicate_operations': duplicate_operations,
        'duplicate_network_requests': duplicate_requests,
        'operations': [
            {'device': device, 'operation': operation, 'result': result,
             'last_stage': stage, 'network_error': error, 'count': count}
            for (device, operation, result, stage, error), count in sorted(operations.items())
        ],
        'network_requests': [
            {'device': device, 'phase': phase, 'reason': reason, 'count': count}
            for (device, phase, reason), count in sorted(requests.items())
        ],
        'correlation': 'request_uuid_match_is_direct; time_overlap_is_coincident',
    }


def main() -> int:
    parser = argparse.ArgumentParser(description='Restricted exact-account diagnostic summary')
    parser.add_argument('--since-hours', type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.since_hours <= 168:
        parser.error('--since-hours must be within 1..168')
    if not sys.stderr.isatty():
        raise SystemExit('Interactive operator terminal required')
    settings = Settings()
    current = settings.diagnostic_identity_secret
    if current is None:
        raise SystemExit('Diagnostic identity key unavailable')
    previous = settings.diagnostic_identity_previous_secret
    handle = getpass.getpass('Current ChatFlow ID: ')
    engine = create_engine(settings)
    try:
        with create_session_factory(engine)() as session:
            session.execute(text('SET TRANSACTION READ ONLY'))
            refs = resolve_refs(session, handle, current.get_secret_value().encode('utf-8'),
                                previous.get_secret_value().encode('utf-8') if previous else None)
    except LookupError:
        raise SystemExit('Account not found') from None
    finally:
        handle = ''
        engine.dispose()
    summary = summarize_account_logs(sys.stdin, refs=refs, since_hours=args.since_hours)
    print(json.dumps(summary, ensure_ascii=True, separators=(',', ':')))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
