"""Public ledger gateway for restriction provenance; legacy restrictions fail closed."""
from datetime import datetime, timezone
import re
from uuid import uuid4
from sqlalchemy import select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.reserve import lock_budget
from app.modules.ledger.restriction_models import LedgerOutgoingRestriction

MANUAL_SCOPE = 'manual_tron'
UNKNOWN_SCOPE = 'legacy_unknown'


def _error(code):
    raise AppError(code=code, message=code, status_code=409)


def snapshot(session):
    reserve = lock_budget(session)
    rows = session.scalars(select(LedgerOutgoingRestriction).order_by(LedgerOutgoingRestriction.scope)).all()
    result = [dict(scope=row.scope, active=row.active, epoch=row.epoch) for row in rows]
    if reserve is not None and reserve.outgoing_restricted and not any(row.active for row in rows):
        result.append(dict(scope=UNKNOWN_SCOPE, active=True, epoch=0))
    return result


def _record(session, row, action, actor_id, reason_code, now):
    payload = dict(scope=row.scope, active=row.active, epoch=row.epoch)
    session.add(AuditEvent(id=str(uuid4()), actor_id=actor_id, subject_type='ledger_reserve',
        subject_id='global', action=action, result='SUCCESS', reason_code=reason_code,
        trace_id=uuid4().hex, after_data=payload, created_at=now))
    OutboxPublisher.enqueue(session, topic='ledger', event_type=action,
        aggregate_type='ledger_reserve', aggregate_id='global', payload=payload, now=now)


def restrict(session, *, actor_id, reason_code, scope=UNKNOWN_SCOPE):
    if (not isinstance(scope, str) or re.fullmatch('[a-z][a-z0-9_]{0,63}', scope) is None
            or not actor_id or len(actor_id) > 36 or not reason_code or len(reason_code) > 100):
        raise ValueError('restriction actor, reason and scope required')
    reserve = lock_budget(session)
    rows = session.scalars(select(LedgerOutgoingRestriction).with_for_update()).all()
    now = datetime.now(timezone.utc)
    # Never let a new named reason relabel an unexplained pre-existing bit.
    if reserve is not None and reserve.outgoing_restricted and not any(row.active for row in rows):
        unknown = next((row for row in rows if row.scope == UNKNOWN_SCOPE), None)
        if unknown is None:
            unknown = LedgerOutgoingRestriction(scope=UNKNOWN_SCOPE, active=True, epoch=1,
                reason_code='LEGACY_RESTRICTION', actor_id=actor_id, updated_at=now)
            session.add(unknown)
            rows.append(unknown)
        else:
            unknown.active, unknown.epoch, unknown.updated_at = True, unknown.epoch+1, now
        _record(session, unknown, 'ledger.outgoing_restricted', actor_id, 'LEGACY_RESTRICTION', now)
    row = next((row for row in rows if row.scope == scope), None)
    if row is None:
        row = LedgerOutgoingRestriction(scope=scope, active=True, epoch=1,
            reason_code=reason_code, actor_id=actor_id, updated_at=now)
        session.add(row)
    else:
        row.active, row.epoch = True, row.epoch+1
        row.reason_code, row.actor_id, row.updated_at = reason_code, actor_id, now
    if reserve is not None:
        reserve.outgoing_restricted = True
        reserve.version += 1
    _record(session, row, 'ledger.outgoing_restricted', actor_id, reason_code, now)
    return row.epoch


def release_manual(session, *, actor_id, reason_code, expected_epoch):
    reserve = lock_budget(session)
    rows = session.scalars(select(LedgerOutgoingRestriction).with_for_update()).all()
    if any(row.active and row.scope != MANUAL_SCOPE for row in rows):
        _error('LEDGER_NON_MANUAL_RESTRICTION')
    row = next((row for row in rows if row.scope == MANUAL_SCOPE), None)
    if reserve is not None and reserve.outgoing_restricted and (row is None or not row.active):
        _error('LEDGER_RESTRICTION_SOURCE_UNKNOWN')
    if row is None or not row.active:
        if expected_epoch is not None:
            _error('LEDGER_RESTRICTION_EPOCH_CONFLICT')
        return
    if row.epoch != expected_epoch:
        _error('LEDGER_RESTRICTION_EPOCH_CONFLICT')
    row.active, row.epoch = False, row.epoch+1
    row.actor_id, row.reason_code, row.updated_at = actor_id, reason_code, datetime.now(timezone.utc)
    if reserve is not None:
        reserve.outgoing_restricted = False
        reserve.version += 1
    _record(session, row, 'ledger.manual_restriction_released', actor_id, reason_code, row.updated_at)
