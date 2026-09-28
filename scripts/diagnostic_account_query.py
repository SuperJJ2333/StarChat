"""Restricted exact-account diagnostic lookup; never exports handles or refs."""

from __future__ import annotations

import argparse
from collections import Counter
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
from app.modules.identity.models import User
from scripts import client_diagnostics_triage as triage


_REF = re.compile(r'^[0-9a-f]{64}$')


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
    earliest = latest = None
    scanned = rejected = matched = uncertain = considered = 0
    duplicate_operations = duplicate_requests = 0
    incomplete = False
    devices: dict[str, str] = {}
    operations: Counter[tuple[str, str, str, str, str]] = Counter()
    requests: Counter[tuple[str, str, str]] = Counter()
    seen_operations: dict[str, tuple[str, str, str, str, str]] = {}
    seen_requests: dict[str, tuple[str, str, str]] = {}
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
        if at < cutoff or at > now or raw.get('event') != 'client_diagnostics':
            continue
        if set(raw) - triage._BATCH_KEYS:
            rejected += 1
            incomplete = True
            continue
        earliest = at if earliest is None or at < earliest else earliest
        latest = at if latest is None or at > latest else latest
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
    def utc(value):
        return value.isoformat(timespec='seconds').replace('+00:00', 'Z') if value else None
    return {
        'scanned_lines': scanned,
        'rejected_lines': rejected,
        'matched_batches': matched,
        'coverage_first_utc': utc(earliest),
        'coverage_last_utc': utc(latest),
        'coverage_incomplete': incomplete or earliest is None,
        'time_uncertain_count': uncertain,
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
        'correlation': 'request_id_matches_are_direct; time_overlap_is_coincident',
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
