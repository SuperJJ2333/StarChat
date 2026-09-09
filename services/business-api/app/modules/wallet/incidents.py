"""Incident bookkeeping only: resolution never releases funds or clears a pause."""
import hashlib
from contextlib import nullcontext
import json
import re
from datetime import datetime, timezone
from uuid import uuid4
from app.integrations.tron import diagnostics as diag

from sqlalchemy import select, text

from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.wallet.incident_models import WalletAlertReceipt, WalletIncident, WalletIncidentCommand


def _error(code, status=409):
    return AppError(code=code, message=code, status_code=status)


def _aware(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _lock(session):
    """All scans/commands share one transaction lock, including absent-row inserts."""
    if session.bind.dialect.name == 'postgresql':
        session.execute(text('SELECT pg_advisory_xact_lock(6821940173493)'))
    elif session.bind.dialect.name == 'sqlite':
        # A caller may already hold SQLite's write lock for its financial write.
        if not session.connection().connection.driver_connection.in_transaction:
            session.execute(text('BEGIN IMMEDIATE'))
    else:
        raise _error('WALLET_INCIDENT_DATABASE_UNSUPPORTED', 503)


def _safe(value, maximum, *, code=False):
    pattern = r'[A-Z][A-Z0-9_]*' if code else r'[A-Za-z0-9][A-Za-z0-9_.:/-]*'
    return isinstance(value, str) and len(value) <= maximum and re.fullmatch(pattern, value) is not None


def _dto(row):
    result = {}
    for column in WalletIncident.__table__.columns:
        value = getattr(row, column.name)
        result[column.name] = _aware(value).isoformat().replace('+00:00', 'Z') if isinstance(value, datetime) else value
    return result


class WalletIncidentService:
    def __init__(self, factory, now_factory=None):
        self.factory = factory
        self.now_factory = now_factory or (lambda: datetime.now(timezone.utc))

    def _record(self, session, row, action, actor, reason, now, key=None, alert=False):
        payload = dict(incident_id=row.id, subject_id=row.subject_id, code=row.code, severity=row.severity)
        session.add(AuditEvent(
            id=str(uuid4()), actor_id=actor, subject_type='wallet_incident', subject_id=row.id,
            action=action, result='SUCCESS', reason_code=reason, trace_id=key or uuid4().hex,
            after_data=dict(status=row.status, generation=row.generation, version=row.version,
                            condition_active=row.condition_active), created_at=now,
        ))
        recorded = OutboxPublisher.enqueue(session, topic='wallet.incident', event_type=action,
                                aggregate_type='wallet_incident', aggregate_id=row.id,
                                payload=payload, now=now)
        diag.after_commit(session, 'incident_committed', component='incidents',
                          incident_id=row.id, event_id=recorded, generation=row.generation,
                          reason_code=row.code, status=row.status, action=action.rsplit('.', 1)[-1])
        if alert:
            alert_event = OutboxPublisher.enqueue(session, topic='wallet.alert', event_type=action,
                                    aggregate_type='wallet_incident', aggregate_id=row.id,
                                    payload=payload, now=now)
            diag.after_commit(session, 'alert_queued', component='incidents',
                              incident_id=row.id, event_id=alert_event, generation=row.generation,
                              reason_code=row.code, status=row.status, action=action.rsplit('.', 1)[-1])

    def observe(self, signals, actor_id='wallet-monitor', complete=True):
        with self.factory.begin() as session:
            return self.observe_in_session(session, signals, actor_id=actor_id, complete=complete)

    def observe_in_session(self, session, signals, actor_id='wallet-monitor', complete=False, clear_prefix=None):
        """Join the caller transaction; never commit a financial caller's work.

        Financial callers acquire reserve/control locks before this incident lock.
        Partial observations cannot clear incidents belonging to other monitors.
        """
        # Validate the complete input before any write; duplicate contradictory keys
        # cannot accidentally clear or overwrite another observation.
        if not _safe(actor_id, 36) or not isinstance(signals, (list, tuple)) or not isinstance(complete, bool):
            raise _error('WALLET_INCIDENT_SIGNAL_INVALID', 422)
        if clear_prefix is not None and (not _safe(clear_prefix, 100) or not clear_prefix.endswith(':')):
            raise _error('WALLET_INCIDENT_SIGNAL_INVALID', 422)
        observed = {}
        for signal in signals:
            if (not isinstance(signal, dict) or set(signal) != {'fingerprint', 'code', 'severity', 'subject_id'}
                    or not _safe(signal['fingerprint'], 128) or not _safe(signal['subject_id'], 128)
                    or not _safe(signal['code'], 100, code=True) or signal['severity'] not in ('P0', 'P1')):
                raise _error('WALLET_INCIDENT_SIGNAL_INVALID', 422)
            if signal['fingerprint'] in observed and observed[signal['fingerprint']] != signal:
                raise _error('WALLET_INCIDENT_FINGERPRINT_CONFLICT')
            observed[signal['fingerprint']] = signal
        now = _aware(self.now_factory())
        _lock(session)
        existing = {row.fingerprint: row for row in session.scalars(select(WalletIncident)).all()}
        result = []
        for fingerprint, signal in observed.items():
            row = existing.get(fingerprint)
            if row and (row.code != signal['code'] or row.subject_id != signal['subject_id']):
                raise _error('WALLET_INCIDENT_FINGERPRINT_CONFLICT')
            if row is None:
                row = WalletIncident(id=str(uuid4()), **signal, status='OPEN', generation=1,
                                     version=1, condition_active=True, opened_at=now,
                                     last_seen_at=now, last_escalation_slot=0)
                session.add(row)
                self._record(session, row, 'wallet.incident.opened', actor_id, row.code, now, alert=True)
            elif not row.condition_active:
                row.generation += 1
                row.version += 1
                row.status = 'OPEN'
                row.condition_active = True
                row.opened_at = now
                row.last_seen_at = now
                row.cleared_at = row.acknowledged_at = row.resolved_at = None
                row.acknowledged_by = row.resolved_by = row.clearance_digest = None
                row.last_escalation_slot = 0
                row.severity = signal['severity']
                self._record(session, row, 'wallet.incident.reopened', actor_id, row.code, now, alert=True)
            else:
                row.last_seen_at = now
                if row.severity != signal['severity']:
                    row.severity = signal['severity']
                    row.version += 1
                    self._record(session, row, 'wallet.incident.severity_changed', actor_id, row.code, now, alert=True)
            result.append(_dto(row))
        for fingerprint, row in existing.items():
            if (complete and fingerprint not in observed and row.condition_active
                    and (clear_prefix is None or fingerprint.startswith(clear_prefix))):
                row.condition_active = False
                row.cleared_at = now
                row.version += 1
                row.clearance_digest = _digest(dict(incident_id=row.id, generation=row.generation,
                                                   version=row.version, scan_id=uuid4().hex,
                                                   cleared_at=now.isoformat()))
                self._record(session, row, 'wallet.incident.condition_cleared', actor_id, row.code, now)
        return result

    def get(self, incident_id):
        with self.factory() as session:
            row = session.get(WalletIncident, incident_id)
            if row is None:
                raise _error('WALLET_INCIDENT_NOT_FOUND', 404)
            return _dto(row)

    def control_snapshot_in_session(self, session):
        """Control callers hold budget/control/identity locks before this lock."""
        _lock(session)
        return [dict(id=row.id, version=row.version, status=row.status, active=row.condition_active)
            for row in session.scalars(select(WalletIncident).order_by(WalletIncident.id)).all()]

    def nonblocking_backing_advisories_in_session(self, session):
        """Exact policy advisory only; no other P1 or arbitrary incident is waived."""
        _lock(session)
        return set(session.scalars(select(WalletIncident.id).where(
            WalletIncident.fingerprint == 'manual-liquidity:backing-deficit',
            WalletIncident.code == 'MANUAL_BACKING_DEFICIT', WalletIncident.severity == 'P1',
            WalletIncident.subject_id == 'global')))

    def require_resolved_in_session(self, session, *, allow_backing_advisory=False):
        rows = self.control_snapshot_in_session(session)
        allowed = self.nonblocking_backing_advisories_in_session(session) if allow_backing_advisory else set()
        if any((row['status'] != 'RESOLVED' or row['active']) and row['id'] not in allowed for row in rows):
            raise _error('WALLET_UNRESOLVED_INCIDENTS')

    def handover_snapshot_in_session(self, session):
        _lock(session)
        return [_dto(row) for row in session.scalars(select(WalletIncident).order_by(WalletIncident.id)).all()]

    def supersede_legacy_in_session(self, session, *, expected, handover_id, manifest_digest, actor_id, reason_code):
        """Only the exact three initial legacy monitor generations may transfer."""
        from app.modules.wallet.handover_models import WalletIncidentHandoverDisposition
        fingerprints = {'MONITOR_UNAVAILABLE:global', 'WALLET_PAUSED:global', 'ALERT_DELIVERY_UNHEALTHY:global'}
        current = self.handover_snapshot_in_session(session)
        if (current != expected or len(current) != 3 or {row['fingerprint'] for row in current} != fingerprints
                or any(row['generation'] != 1 or row['status'] != 'OPEN' or not row['condition_active'] for row in current)):
            raise _error('HANDOVER_INCIDENT_SET_CONFLICT')
        now = _aware(self.now_factory())
        for value in current:
            row = session.get(WalletIncident, value['id'])
            session.add(WalletIncidentHandoverDisposition(incident_id=row.id, generation=row.generation,
                handover_id=handover_id, manifest_digest=manifest_digest, successor_scope='manual_tron',
                disposition='LEGACY_MONITOR_SUPERSEDED', actor_id=actor_id, reason_code=reason_code, created_at=now))
            row.status, row.condition_active = 'RESOLVED', False
            row.acknowledged_by, row.resolved_by = actor_id, actor_id
            row.acknowledged_at, row.resolved_at, row.cleared_at = now, now, now
            row.version += 1
            # This digest links retirement/ownership, not reserve health.
            row.clearance_digest = manifest_digest
            self._record(session, row, 'wallet.incident.legacy_superseded', actor_id, reason_code, now,
                key=manifest_digest)
            from app.modules.audit.writer import AuditWriter
            AuditWriter(self.factory, now_factory=lambda: now).record_in_session(session, actor_id=actor_id,
                subject_type='wallet_incident', subject_id=row.id, action='wallet.incident.handover_disposition',
                result='SUCCESS', reason_code=reason_code, trace_id=manifest_digest,
                after=dict(disposition='LEGACY_MONITOR_SUPERSEDED', successor_scope='manual_tron',
                    handover_id=handover_id, generation=row.generation, funds_paused=True))

    def list_incidents(self, limit=50, cursor=None):
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise _error('WALLET_INCIDENT_PAGE_INVALID', 422)
        if cursor is not None and not _safe(cursor, 36):
            raise _error('WALLET_INCIDENT_PAGE_INVALID', 422)
        with self.factory() as session:
            query = select(WalletIncident).order_by(WalletIncident.id)
            if cursor:
                query = query.where(WalletIncident.id > cursor)
            rows = session.scalars(query.limit(limit + 1)).all()
            return dict(items=[_dto(row) for row in rows[:limit]],
                        next_cursor=rows[limit - 1].id if len(rows) > limit else None)

    def ack(self, incident_id, actor_id, reason_code, idempotency_key, expected_version, *, authorize=None):
        return self._command('ack', incident_id, actor_id, reason_code, idempotency_key, expected_version,
            authorize=authorize)

    def resolve(self, incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest):
        return self._command('resolve', incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest)

    def resolve_manual(self, incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest,
                       *, session=None, authorize=None):
        """OWNER_MANUAL_V1 gateway supplies the authenticated configured owner.

        This distinct command only closes this monitor's incident record. It
        does not release a restriction, publish reserve evidence, or move funds.
        """
        return self._command('resolve_manual', incident_id, actor_id, reason_code,
            idempotency_key, expected_version, clearance_digest, session=session, authorize=authorize)

    def review_manual(self, incident_id, actor_id, reason_code, idempotency_key, expected_version,
                      *, session, authorize):
        """Commit clearance and its immutable command result in the scan transaction."""
        return self._command('review_manual', incident_id, actor_id, reason_code,
            idempotency_key, expected_version, session=session, authorize=authorize)

    def replay_manual_review(self, incident_id, actor_id, reason_code, idempotency_key, expected_version,
                             *, authorize):
        return self._replay_resolution('review_manual', incident_id, actor_id, reason_code,
            idempotency_key, expected_version, None, authorize=authorize)

    def replay_manual_resolve(self, incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest,
                              *, authorize=None):
        return self._replay_resolution('resolve_manual', incident_id, actor_id, reason_code,
            idempotency_key, expected_version, clearance_digest, authorize=authorize)

    def replay_resolve(self, incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest):
        """Immutable command evidence can be read before re-scanning current conditions."""
        return self._replay_resolution('resolve', incident_id, actor_id, reason_code,
            idempotency_key, expected_version, clearance_digest)

    def _replay_resolution(self, command, incident_id, actor_id, reason_code, idempotency_key, expected_version, clearance_digest,
                           *, authorize=None):
        digest = _digest(dict(command=command, incident_id=incident_id, actor_id=actor_id,
            reason_code=reason_code, expected_version=expected_version, clearance_digest=clearance_digest))
        with self.factory.begin() as session:
            fresh = authorize(session) if authorize is not None else None
            if fresh is not None:
                fresh()
            replay = session.get(WalletIncidentCommand, idempotency_key)
            if replay is None:
                return None
            if replay.payload_digest != digest:
                raise _error('WALLET_INCIDENT_IDEMPOTENCY_CONFLICT')
            return replay.result

    def _command(self, command, incident_id, actor_id, reason_code, key, version, clearance=None,
                 *, session=None, authorize=None):
        if (not _safe(actor_id, 36) or not _safe(reason_code, 100, code=True)
                or not isinstance(key, str) or not key.strip() or len(key) > 128
                or isinstance(version, bool) or not isinstance(version, int) or version < 1):
            raise _error('WALLET_INCIDENT_COMMAND_INVALID', 422)
        payload_digest = _digest(dict(command=command, incident_id=incident_id, actor_id=actor_id,
                                      reason_code=reason_code, expected_version=version, clearance_digest=clearance))
        with self.factory.begin() if session is None else nullcontext(session) as session:
            fresh = authorize(session) if authorize is not None else None
            _lock(session)
            if fresh is not None:
                fresh()
            now = _aware(self.now_factory())
            replay = session.get(WalletIncidentCommand, key)
            if replay:
                if replay.payload_digest != payload_digest:
                    raise _error('WALLET_INCIDENT_IDEMPOTENCY_CONFLICT')
                return replay.result
            row = session.get(WalletIncident, incident_id)
            if row is None:
                raise _error('WALLET_INCIDENT_NOT_FOUND', 404)
            if row.version != version:
                raise _error('WALLET_INCIDENT_VERSION_CONFLICT')
            if command == 'ack':
                if row.status != 'OPEN':
                    raise _error('WALLET_INCIDENT_ACK_REQUIRED_OPEN')
                row.status = 'ACKNOWLEDGED'
                row.acknowledged_by = actor_id
                row.acknowledged_at = now
            elif command == 'review_manual':
                if not row.fingerprint.startswith('manual-reserve:') or row.subject_id != 'global':
                    raise _error('WALLET_INCIDENT_MANUAL_SCOPE_REQUIRED')
                self.observe_in_session(session, [], actor_id=actor_id, complete=True,
                    clear_prefix='manual-reserve:')
                result = _dto(row)
                session.add(WalletIncidentCommand(idempotency_key=key, payload_digest=payload_digest,
                    result=result, created_at=now))
                self._record(session, row, 'wallet.manual_incident.reviewed', actor_id, reason_code, now, key=key)
                return result
            else:
                if row.status != 'ACKNOWLEDGED':
                    raise _error('WALLET_INCIDENT_ACK_REQUIRED')
                if command == 'resolve_manual' and (not row.fingerprint.startswith('manual-reserve:')
                        or row.subject_id != 'global' or row.acknowledged_by != actor_id):
                    raise _error('WALLET_INCIDENT_MANUAL_SCOPE_REQUIRED')
                if command != 'resolve_manual' and row.acknowledged_by == actor_id:
                    raise _error('WALLET_INCIDENT_SEPARATE_REVIEWER_REQUIRED')
                if row.condition_active or not row.clearance_digest or row.clearance_digest != clearance:
                    raise _error('WALLET_INCIDENT_CLEARANCE_REQUIRED')
                row.status = 'RESOLVED'
                row.resolved_by = actor_id
                row.resolved_at = now
            row.version += 1
            result = _dto(row)
            session.add(WalletIncidentCommand(idempotency_key=key, payload_digest=payload_digest, result=result, created_at=now))
            self._record(session, row, 'wallet.incident.' + command, actor_id, reason_code, now, key=key)
            return result

    def escalate(self):
        now = _aware(self.now_factory())
        with self.factory.begin() as session:
            _lock(session)
            rows = session.scalars(select(WalletIncident).where(
                WalletIncident.severity == 'P0', WalletIncident.status == 'OPEN')).all()
            result = []
            for row in rows:
                slot = int((now - _aware(row.opened_at)).total_seconds() // 300)
                if slot >= 1 and slot > row.last_escalation_slot:
                    row.last_escalation_slot = slot
                    row.version += 1
                    self._record(session, row, 'wallet.incident.escalated', 'wallet-monitor',
                                 'UNACKNOWLEDGED_P0', now, alert=True)
                    result.append(_dto(row))
            return result


class SandboxWalletAlertHandler:
    """Durable local acceptance only; performs no external delivery."""
    def __init__(self, factory):
        self.factory = factory

    def __call__(self, event):
        payload = event.payload
        if (event.topic != 'wallet.alert' or set(payload) != {'incident_id', 'subject_id', 'code', 'severity'}
                or not _safe(payload['incident_id'], 36) or not _safe(payload['subject_id'], 128)
                or not _safe(payload['code'], 100, code=True) or payload['severity'] not in ('P0', 'P1')):
            raise _error('WALLET_ALERT_PAYLOAD_INVALID', 422)
        with self.factory.begin() as session:
            _lock(session)
            existing = session.get(WalletAlertReceipt, event.id)
            if existing:
                if existing.payload != payload:
                    raise _error('WALLET_ALERT_EVENT_CONFLICT')
                return
            session.add(WalletAlertReceipt(event_id=event.id, incident_id=payload['incident_id'],
                                            transport='SANDBOX', payload=payload,
                                            created_at=datetime.now(timezone.utc)))
