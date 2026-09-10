"""Bounded, allowlisted diagnostics; also importable by the isolated tron process.

Never pass exception text, request objects, bodies, headers or financial values.
SQLAlchemy is imported only by the optional business transaction integration.
"""
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime, timezone
import json
import logging
import os
import re
import sys
import time
from uuid import uuid4

_trace = ContextVar('wallet_diagnostic_trace', default=None)
_logger = logging.getLogger('wallet.diagnostics')
_service = 'business-api'
_configured = False
_numbers = frozenset(('duration_ms', 'http_status', 'run_id', 'observation_id',
    'checkpoint_ms', 'solid_block', 'solid_timestamp_ms', 'heartbeat_age_ms',
    'observation_age_ms', 'solid_head_age_ms', 'freshness_limit_ms', 'fresh_until_ms',
    'pending_age_ms', 'generation', 'events_added', 'page_count', 'transaction_count',
    'budget_ms', 'suppressed_count', 'waited_ms', 'previous_observation_id', 'poll_count'))
_ids = frozenset(('trace_id', 'request_id', 'incident_id', 'event_id'))
_states = {}
ROUTES = {'head': '/walletsolidity/getnowblock', 'balance': '/walletsolidity/triggerconstantcontract',
          'receipt': '/walletsolidity/gettransactioninfobyid',
          'history': '/v1/accounts/{address}/transactions/trc20'}
_conditions = frozenset(('CLOCK_AHEAD', 'SOLID_HEAD_STALE', 'OBSERVATION_STALE', 'HEARTBEAT_STALE',
    'SOURCE_RUN_ERROR', 'BALANCE_UNSTABLE', 'RECONCILIATION_PENDING', 'BALANCE_DISCREPANCY'))


class _SafeHandler(logging.StreamHandler):
    def handleError(self, record):
        # StreamHandler's default prints the record/traceback on failure.
        # Financial processing must not fail when diagnostic storage fails.
        try:
            sys.__stderr__.write('{"level":"ERROR","event":"diagnostic_sink_failed"}\n')
        except Exception:
            pass


def configure(service, *, level=None, stream=None):
    global _configured, _service
    level = level or os.environ.get('WALLET_DIAGNOSTIC_LOG_LEVEL', 'INFO')
    if level not in ('ERROR', 'WARNING', 'INFO', 'DEBUG'):
        raise ValueError('INVALID_DIAGNOSTIC_LOG_LEVEL')
    if service not in ('business-api', 'business-worker', 'tron-watch', 'test'):
        raise ValueError('INVALID_DIAGNOSTIC_SERVICE')
    _service = service
    _logger.handlers[:] = [_SafeHandler(stream)]
    _logger.setLevel(level)
    _logger.disabled = False
    _logger.propagate = False
    # Even component DEBUG must not enable libraries' URL/body diagnostics.
    logging.getLogger('httpx').setLevel(logging.WARNING)
    logging.getLogger('httpcore').setLevel(logging.WARNING)
    _configured = True


@contextmanager
def span(component):
    token = _trace.set(uuid4().hex)
    try:
        yield _trace.get()
    finally:
        _trace.reset(token)


def traced(component):
    from functools import wraps
    def decorate(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            with span(component):
                return function(*args, **kwargs)
        return wrapped
    return decorate


def emit(level, event, *, component, **fields):
    try:
        if not _configured:
            configure('business-api')
        data = dict(timestamp=datetime.now(timezone.utc).isoformat(), schema_version=1,
                    service=_service, component=component, event=event, level=level,
                    trace_id=_trace.get() or uuid4().hex)
        for key, value in fields.items():
            if key in _numbers and type(value) is int and -(2**63) < value < 2**63:
                data[key] = value
            elif key in _ids and isinstance(value, str) and re.fullmatch(r'[0-9a-f-]{32,36}', value):
                data[key] = value
            elif key in ('reason_code', 'status', 'reconciliation') and isinstance(value, str) and re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}', value):
                data[key] = value
            elif key == 'stage' and value in ('head', 'balance', 'history', 'receipt', 'unknown'):
                data[key] = value
                if value in ROUTES:
                    data['route'] = ROUTES[value]
            elif key == 'failed_conditions' and isinstance(value, list):
                data[key] = [item for item in value[:8] if isinstance(item, str) and item in _conditions]
            elif key == 'action' and value in ('opened', 'reopened', 'severity_changed',
                    'condition_cleared', 'legacy_superseded', 'reviewed', 'ack', 'resolve',
                    'resolve_manual', 'escalated'):
                data[key] = value
            elif key == 'exception_type' and value in ('ConnectTimeout', 'ReadTimeout', 'WriteTimeout',
                    'PoolTimeout', 'ConnectError', 'HTTPStatusError', 'RemoteProtocolError',
                    'JSONDecodeError', 'TronReadError', 'ObservationError', 'OSError', 'TimeoutError', 'UNKNOWN'):
                data[key] = value
            elif key == 'frames' and isinstance(value, list):
                # Only this module's exception_info creates these tuples.
                data[key] = [list(frame) for frame in value[:8] if isinstance(frame, tuple)
                    and len(frame) == 3 and re.fullmatch(r'[a-z_]+\.py', frame[0])
                    and re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,79}', frame[1]) and type(frame[2]) is int]
        _logger.log(getattr(logging, level), json.dumps(data, separators=(',', ':')))
    except Exception:
        # Diagnostics never replace the original outcome.
        pass


def exception_info(exc):
    frames = []
    current = exc.__traceback__
    while current is not None:
        code = current.tb_frame.f_code
        path = code.co_filename.replace('\\', '/')
        if '/app/' in path or '/tron/' in path or '/tasks/' in path:
            frames.append((path.rsplit('/', 1)[-1], code.co_name, current.tb_lineno))
        current = current.tb_next
    name = type(exc).__name__
    if name not in ('ConnectTimeout', 'ReadTimeout', 'WriteTimeout', 'PoolTimeout',
            'ConnectError', 'HTTPStatusError', 'RemoteProtocolError', 'JSONDecodeError',
            'TronReadError', 'ObservationError', 'OSError', 'TimeoutError'):
        name = 'UNKNOWN'
    return dict(exception_type=name, frames=frames[-8:])


def validation_reason(exc):
    # Lookup only: no exception text is returned, even for unexpected providers.
    reasons = {
        'TRON request failed': 'UPSTREAM_REQUEST_FAILED',
        'TRON scan deadline exceeded': 'SCAN_DEADLINE',
        'TRON solid head regressed': 'SOLID_HEAD_REGRESSED',
        'TRON solid head conflicted': 'SOLID_HEAD_CONFLICT',
        'TRON history page cap exceeded': 'PAGE_LIMIT',
        'TRON history page exceeds cap': 'PAGE_LIMIT',
        'TRON transaction cap exceeded': 'TRANSACTION_LIMIT',
        'Observation window is not solidified yet': 'WINDOW_NOT_SOLIDIFIED',
        'Malformed TRON response': 'INVALID_RESPONSE',
        'Malformed solid block': 'INVALID_SOLID_BLOCK',
        'Malformed TRON integer': 'INVALID_INTEGER',
        'Malformed TRON ABI word': 'INVALID_ABI_WORD',
        'Malformed TRON history page': 'INVALID_HISTORY_PAGE',
        'Malformed TRON history row': 'INVALID_HISTORY_ROW',
        'Malformed TRON pagination links': 'INVALID_PAGINATION',
        'TRON pagination cursor missing': 'PAGINATION_CURSOR_MISSING',
        'Invalid TRON pagination cursor': 'INVALID_PAGINATION',
        'Unverified TRON receipt': 'RECEIPT_UNVERIFIED',
        'TRON receipt outside finalized window': 'RECEIPT_OUTSIDE_WINDOW',
        'Malformed TRON logs': 'INVALID_LOGS',
        'Malformed TRON log': 'INVALID_LOG',
        'Malformed TRON topics': 'INVALID_TOPICS',
        'Malformed Transfer topics': 'INVALID_TRANSFER_TOPICS',
        'Malformed Transfer address': 'INVALID_TRANSFER_ADDRESS',
        'History transaction has no matching USDT Transfer': 'TRANSFER_MISSING',
        'Unverified TRON balance result': 'BALANCE_UNVERIFIED',
        'INVALID_SNAPSHOT': 'INVALID_SNAPSHOT', 'CLOCK_REGRESSION': 'CLOCK_REGRESSION',
        'EVENT_CONFLICT': 'EVENT_CONFLICT', 'SOLID_HEAD_BEHIND_CHECKPOINT': 'SOLID_HEAD_BEHIND_CHECKPOINT',
    }
    return reasons.get(exc.args[0], 'UNKNOWN') if exc.args and type(exc.args[0]) is str else 'UNKNOWN'


def source_health(*, now_ms, heartbeat, observed, solid_ms, max_age_seconds,
                  head_limit, observation_id, status, stable, reconciliation, healthy,
                  run_id=None, fresh_until_ms=None):
    fields = dict(heartbeat_age_ms=now_ms-heartbeat, observation_age_ms=now_ms-observed,
                  solid_head_age_ms=now_ms-solid_ms, freshness_limit_ms=head_limit*1000,
                  observation_id=observation_id, status=status, reconciliation=reconciliation,
                  run_id=run_id, fresh_until_ms=fresh_until_ms)
    failed = []
    for condition, matched in (
        ('CLOCK_AHEAD', min(now_ms-heartbeat, now_ms-observed, now_ms-solid_ms) < 0),
        ('SOLID_HEAD_STALE', now_ms-solid_ms > head_limit*1000),
        ('OBSERVATION_STALE', now_ms-observed > max_age_seconds*1000),
        ('HEARTBEAT_STALE', now_ms-heartbeat > max_age_seconds*1000),
        ('SOURCE_RUN_ERROR', status != 'OK'), ('BALANCE_UNSTABLE', not stable),
        ('RECONCILIATION_PENDING', reconciliation == 'RECONCILIATION_UNVERIFIED'),
        ('BALANCE_DISCREPANCY', reconciliation == 'BALANCE_DISCREPANCY')):
        if matched:
            failed.append(condition)
    fields['failed_conditions'] = failed
    if healthy:
        reason = 'SOURCE_HEALTHY'
    elif min(now_ms-heartbeat, now_ms-observed, now_ms-solid_ms) < 0:
        reason = 'CLOCK_AHEAD'
    elif now_ms-solid_ms > head_limit*1000:
        reason = 'SOLID_HEAD_STALE'
    elif now_ms-observed > max_age_seconds*1000:
        reason = 'OBSERVATION_STALE'
    elif now_ms-heartbeat > max_age_seconds*1000:
        reason = 'HEARTBEAT_STALE'
    elif status != 'OK':
        reason = 'SOURCE_RUN_ERROR'
    elif not stable:
        reason = 'BALANCE_UNSTABLE'
    elif reconciliation != 'SOURCE_MATCHED':
        reason = 'RECONCILIATION_PENDING' if reconciliation == 'RECONCILIATION_UNVERIFIED' else 'BALANCE_DISCREPANCY'
    else:
        reason = 'SOURCE_RUN_ERROR'
    state('INFO' if healthy else 'WARNING', 'source_health', component='funding_source',
          reason_code=reason, **fields)
    emit('DEBUG', 'source_checked', component='funding_source', reason_code=reason, **fields)


def state(level, event, *, component, reason_code, **fields):
    """Bounded per-component state suppression; changes are emitted immediately."""
    key = (component, event)
    previous = _states.get(key)
    now = time.monotonic()
    count = 0 if previous is None else previous[2]
    if previous and previous[0] == reason_code and now-previous[1] < 60:
        _states[key] = (reason_code, previous[1], count+1)
        return
    if len(_states) >= 32:
        _states.clear()
    _states[key] = (reason_code, now, 0)
    emit(level, event, component=component, reason_code=reason_code, suppressed_count=count, **fields)


def after_commit(session, event, *, component, **fields):
    """Queue immutable metadata, scoped to the current transaction/savepoint."""
    from sqlalchemy import event as sa_event
    key = 'wallet_diagnostic_queue'
    if not session.info.get('wallet_diagnostic_listeners'):
        def committed(current):
            nested = current.get_nested_transaction()
            queue = current.info.get(key, [])
            if nested is not None:
                current.info[key] = [(nested.parent if tx is nested else tx, payload) for tx, payload in queue]
            else:
                for _, payload in current.info.pop(key, []):
                    emit('INFO', **payload)
        def rolled_back(current, transaction):
            queue = current.info.get(key, [])
            def belongs_to_ended(tx):
                while tx is not None:
                    if tx is transaction:
                        return True
                    tx = tx.parent
                return False
            current.info[key] = [(tx, p) for tx, p in queue if not belongs_to_ended(tx)]
        sa_event.listen(session, 'after_commit', committed)
        sa_event.listen(session, 'after_soft_rollback', rolled_back)
        # close() and ancestor savepoint rollback also abandon queued records.
        # Successful nested commits were promoted to their parent above.
        sa_event.listen(session, 'after_transaction_end', rolled_back)
        session.info['wallet_diagnostic_listeners'] = True
    transaction = session.get_nested_transaction() or session.get_transaction()
    payload = dict(event=event, component=component, **fields)
    payload['trace_id'] = _trace.get() or uuid4().hex
    session.info.setdefault(key, []).append((transaction, payload))
