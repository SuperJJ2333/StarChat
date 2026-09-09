"""Exact no-legacy-funds handover; ownership changes only after delivered notice and fresh proof."""
from datetime import timedelta, timezone
import re
import time
from uuid import uuid4
from sqlalchemy import func, select
from app.core.errors import AppError, FieldError
from app.core.outbox import OutboxPublisher
from app.core.outbox_handover import OutboxHandover, digest
from app.modules.audit.models import AuditEvent
from app.modules.audit.writer import AuditWriter
from app.modules.ledger.handover import handover_history_snapshot
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.handover_deployment import POLICY, aware, load_deployment
from app.modules.wallet.handover_models import WalletHandoverPreparation, WalletHandoverCommand, WalletIncidentHandoverDisposition
from app.modules.wallet.handover_ownership import adopt_legacy_stop
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.incident_models import WalletAlertReceipt
from app.modules.wallet.manual_control_models import WalletManualControlState
from app.modules.wallet.models import (WalletControl, WalletSafetyState, Deposit, Withdrawal, WalletPayoutIntent,
    WalletLedgerEntry, WalletLedgerTransaction, WalletConversion)
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly
from app.modules.wallet.manual_payout_models import ManualPayoutQuote, ManualPayoutOrder, ManualPayoutEvent, ManualPayoutCandidate
from app.modules.wallet.monitor_lock import monitor_scan_lock

FINGERPRINTS = {'MONITOR_UNAVAILABLE:global', 'WALLET_PAUSED:global', 'ALERT_DELIVERY_UNHEALTHY:global'}
FINANCIAL_MODELS = (Deposit, Withdrawal, WalletPayoutIntent, WalletLedgerEntry, WalletLedgerTransaction,
    WalletConversion, DepositReceipt, DepositReceiptAnomaly, ManualPayoutQuote, ManualPayoutOrder,
    ManualPayoutEvent, ManualPayoutCandidate)

_TRANSIENT_PROOFS = frozenset({('WAITING', 'MANUAL_SOURCE_PENDING'),
    ('WAITING', 'MANUAL_COVERAGE_PENDING'), ('BLOCKED', 'MANUAL_COVERAGE_PENDING'),
    ('RETRY', 'MONITOR_SCAN_BUSY'),
    ('RETRY', 'MANUAL_SOURCE_CHANGED'), ('RETRY', 'MANUAL_RESERVE_CHANGED')})
_SAFE_PROOF_REASONS = frozenset(code for _, code in _TRANSIENT_PROOFS) | {
    'MANUAL_COVERAGE_CONFLICT', 'MANUAL_SOURCE_UNHEALTHY', 'MANUAL_SOURCE_UNAVAILABLE',
    'LEDGER_INTEGRITY', 'HANDOVER_PROOF_DEADLINE', 'HANDOVER_PROOF_REJECTED'}


def _proof_unavailable(reason):
    safe = reason if reason in _SAFE_PROOF_REASONS else 'HANDOVER_PROOF_REJECTED'
    raise AppError(code='HANDOVER_EVIDENCE_UNAVAILABLE', message='HANDOVER_EVIDENCE_UNAVAILABLE',
        status_code=503, fields=[FieldError(loc=['evidence'], msg=safe, type='wallet.handover.evidence')])


def reject(code, status=409):
    raise AppError(code=code, message=code, status_code=status)


def iso(value):
    return (value if value.tzinfo else value.replace(tzinfo=timezone.utc)).isoformat()


class LegacyWalletHandover:
    def __init__(self, factory, *, monitor, deployment_record_path, clock, preparation_mode, funds_enabled):
        self.factory, self.monitor, self.path, self.clock = factory, monitor, deployment_record_path, clock
        self.preparation_mode, self.funds_enabled = preparation_mode, funds_enabled
        self.incidents = WalletIncidentService(factory, now_factory=clock)
        self.outbox = OutboxHandover(factory, clock=clock)

    def _mode(self):
        if self.preparation_mode() is not True or self.funds_enabled() is not False:
            reject('HANDOVER_PREPARATION_MODE_REQUIRED', 503)

    def _lock(self, session, authorize):
        lock_budget(session)
        session.get(WalletControl, 'global', with_for_update=True)
        return authorize(session)

    def _manifest(self, session):
        deployment = load_deployment(self.path, monitor=self.monitor, now=self.clock())
        financial = handover_history_snapshot(session)
        for model in FINANCIAL_MODELS:
            count = session.scalar(select(func.count()).select_from(model))
            if count:
                reject('HANDOVER_FINANCIAL_HISTORY_PRESENT')
            financial[model.__tablename__] = 0
        control = session.get(WalletControl, 'global', with_for_update=True)
        safety = session.get(WalletSafetyState, 'global', with_for_update=True)
        if (control is None or not control.withdrawals_paused or control.pause_reason != 'WALLET_MONITOR_SIGNAL'
                or safety is None or not safety.restricted or safety.epoch != 1 or safety.reason != 'WALLET_MONITOR_SIGNAL'
                or session.get(WalletManualControlState, 'global') is not None
                or session.scalar(select(WalletSafetyState.id).where(WalletSafetyState.id != 'global', WalletSafetyState.restricted.is_(True)).limit(1))):
            reject('HANDOVER_RESTRICTION_CONFLICT')
        incidents = self.incidents.handover_snapshot_in_session(session)
        if (len(incidents) != 3 or {row['fingerprint'] for row in incidents} != FINGERPRINTS
                or any(row['subject_id'] != 'global' or row['generation'] != 1 or row['status'] != 'OPEN'
                    or not row['condition_active'] or row['code']+':global' != row['fingerprint'] for row in incidents)):
            reject('HANDOVER_INCIDENT_SET_CONFLICT')
        retired = aware(deployment['record']['old_monitor_retired_at'])
        if any(not aware(row['opened_at']) <= aware(row['last_seen_at']) <= retired for row in incidents):
            reject('HANDOVER_INCIDENT_PROVENANCE_CONFLICT')
        pauses = session.scalars(select(AuditEvent).where(AuditEvent.subject_id == 'global',
            ((AuditEvent.subject_type == 'wallet') & AuditEvent.action.in_(('wallet.paused','wallet.restricted')))
            | AuditEvent.subject_type.in_(('wallet_control','ledger_reserve'))).order_by(AuditEvent.created_at, AuditEvent.id)).all()
        if (len(pauses) != 1 or pauses[0].actor_id != 'wallet-monitor' or pauses[0].action != 'wallet.paused'
                or pauses[0].reason_code != 'RECONCILIATION_MISMATCH' or pauses[0].result != 'SUCCESS'
                or not aware(iso(pauses[0].created_at)) <= min(aware(row['opened_at']) for row in incidents)
                    <= aware(iso(pauses[0].created_at))+timedelta(seconds=60)):
            reject('HANDOVER_PAUSE_PROVENANCE_CONFLICT')
        audits = []
        for row in incidents:
            history = session.scalars(select(AuditEvent).where(AuditEvent.subject_type == 'wallet_incident',
                AuditEvent.subject_id == row['id']).order_by(AuditEvent.created_at, AuditEvent.id)).all()
            opens = [item for item in history if item.action == 'wallet.incident.opened']
            if (len(opens) != 1 or len(history) != row['version'] or any(item.actor_id != 'wallet-monitor'
                    or item.action not in ('wallet.incident.opened','wallet.incident.escalated') or item.result != 'SUCCESS'
                    or aware(iso(item.created_at)) > retired or not isinstance(item.after_data, dict)
                    or item.after_data.get('generation') != 1 for item in history)
                    or sorted(item.after_data.get('version', 0) for item in history) != list(range(1, row['version']+1))
                    or aware(iso(opens[0].created_at)) != aware(row['opened_at'])):
                reject('HANDOVER_INCIDENT_PROVENANCE_CONFLICT')
            audits.extend(history)
        ids = [row['id'] for row in incidents]
        if session.scalar(select(WalletAlertReceipt.event_id).where(WalletAlertReceipt.incident_id.in_(ids)).limit(1)):
            reject('HANDOVER_UNEXPECTED_LEGACY_RECEIPT')
        events = self.outbox.capture(session, incident_ids=ids)
        if not events:
            reject('HANDOVER_ALERT_SET_CONFLICT')
        by_id = {row['id']:row for row in incidents}
        for event in events:
            row = by_id[event['aggregate_id']]
            if event['payload_digest'] != digest(dict(incident_id=row['id'], subject_id='global', code=row['code'], severity=row['severity'])):
                reject('HANDOVER_ALERT_PAYLOAD_CONFLICT')
        def audit_data(item):
            return dict(id=item.id, actor_id=item.actor_id, action=item.action, result=item.result,
                reason_code=item.reason_code, created_at=iso(item.created_at), after_digest=digest(item.after_data))
        return dict(policy=POLICY, deployment=deployment, financial=financial,
            control=dict(paused=True, reason=control.pause_reason), safety=dict(restricted=True, epoch=safety.epoch, reason=safety.reason),
            incidents=incidents, pause_audits=[audit_data(row) for row in pauses],
            incident_audits=[audit_data(row) for row in sorted(audits,key=lambda item:item.id)], alerts=events)

    def _view(self, session, preparation):
        id, delivered = self.outbox.notice_status(session, manifest_digest=preparation.manifest_digest)
        complete = session.scalar(select(func.count()).select_from(WalletIncidentHandoverDisposition).where(
            WalletIncidentHandoverDisposition.manifest_digest == preparation.manifest_digest)) == 3
        expired = self.clock() > aware(iso(preparation.expires_at))
        status = 'HANDOVER_COMPLETE_FUNDS_PAUSED' if complete else 'EXPIRED' if expired else (
            'NOTICE_DELIVERED' if delivered else 'NOTICE_PENDING' if id else 'PREPARED')
        return dict(id=preparation.id, manifest_digest=preparation.manifest_digest, expires_at=iso(preparation.expires_at),
            status=status, incident_count=3, alert_count=len(preparation.manifest['alerts']), notice_id=id,
            disposition_kind='LEGACY_MONITOR_SUPERSEDED' if complete else None, withdrawals_paused=True, invalid_reason=None,
            incidents=[{key:item[key] for key in ('id','code','fingerprint','generation','version')} for item in preparation.manifest['incidents']],
            source_configuration_version=preparation.manifest['deployment']['record']['manual_config_version'],
            deployment_record_sha256=preparation.manifest['deployment']['file_sha256'])

    def _preparation(self, session, id, actor_id):
        row = session.get(WalletHandoverPreparation, id)
        if row is None or row.actor_id != actor_id:
            reject('HANDOVER_PREPARATION_NOT_FOUND', 404)
        return row

    def _current(self, session, preparation, expected):
        if expected != preparation.manifest_digest:
            reject('HANDOVER_MANIFEST_CONFLICT')
        if self.clock() > aware(iso(preparation.expires_at)):
            reject('HANDOVER_PREPARATION_EXPIRED')
        try:
            current = self._manifest(session)
        except AppError as error:
            if error.status_code == 409:
                reject('HANDOVER_MANIFEST_CONFLICT')
            raise
        if digest(current) != expected:
            reject('HANDOVER_MANIFEST_CONFLICT')

    def status(self, id, *, actor_id):
        with self.factory.begin() as session:
            lock_budget(session)
            row = self._preparation(session, id, actor_id)
            result = self._view(session, row)
            if result['status'] not in ('EXPIRED','HANDOVER_COMPLETE_FUNDS_PAUSED'):
                try:
                    self._current(session, row, row.manifest_digest)
                except AppError as error:
                    result['status'], result['invalid_reason'] = 'INVALID', error.code
            return result

    @staticmethod
    def _valid(actor_id, reason_code, key):
        if (not isinstance(actor_id,str) or re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]{0,35}',actor_id) is None
                or not isinstance(reason_code,str) or re.fullmatch('[A-Z][A-Z0-9_]{2,99}',reason_code) is None
                or not isinstance(key,str) or not key.strip() or len(key)>128):
            reject('HANDOVER_COMMAND_INVALID',422)

    def prepare(self, *, actor_id, reason_code, idempotency_key, authorize):
        self._valid(actor_id,reason_code,idempotency_key)
        payload = digest(dict(actor_id=actor_id,reason_code=reason_code,policy=POLICY))
        with monitor_scan_lock(self.factory) as acquired:
            if not acquired:
                reject('HANDOVER_MONITOR_BUSY')
            with self.factory.begin() as session:
                fresh = self._lock(session, authorize)
                existing = session.scalar(select(WalletHandoverPreparation).where(
                    WalletHandoverPreparation.actor_id==actor_id,WalletHandoverPreparation.idempotency_key==idempotency_key))
                if existing is not None:
                    if existing.payload_digest != payload:
                        reject('HANDOVER_IDEMPOTENCY_CONFLICT')
                    fresh()
                    return self._view(session, existing)
                self._mode()
                manifest = self._manifest(session)
                now = self.clock()
                row = WalletHandoverPreparation(id=str(uuid4()),actor_id=actor_id,idempotency_key=idempotency_key,
                    payload_digest=payload,manifest_digest=digest(manifest),manifest=manifest,created_at=now,expires_at=now+timedelta(minutes=15))
                session.add(row)
                self._audit(session,row,actor_id,reason_code,'prepared')
                fresh()
                return self._view(session,row)

    def _audit(self,session,row,actor_id,reason_code,operation):
        payload=dict(preparation_id=row.id,manifest_digest=row.manifest_digest,funds_paused=True)
        AuditWriter(self.factory,now_factory=self.clock).record_in_session(session,actor_id=actor_id,
            subject_type='wallet_handover',subject_id=row.id,action='wallet.handover.'+operation,
            result='SUCCESS',reason_code=reason_code,trace_id=row.manifest_digest,after=payload)
        OutboxPublisher.enqueue(session,topic='wallet',event_type='wallet.handover.'+operation,
            aggregate_type='wallet_handover',aggregate_id=row.id,payload=payload,now=self.clock())

    def _replay(self,session,key,payload):
        row=session.get(WalletHandoverCommand,key)
        if row is not None:
            if row.payload_digest != payload:
                reject('HANDOVER_IDEMPOTENCY_CONFLICT')
            return row.result

    def _command(self,session,row,*,key,payload,actor_id,reason_code,operation):
        self._audit(session,row,actor_id,reason_code,operation)
        session.flush()
        result=self._view(session,row)
        session.add(WalletHandoverCommand(idempotency_key=key,payload_digest=payload,result=result,created_at=self.clock()))
        session.flush()
        return result

    def notify(self,*,preparation_id,manifest_digest,actor_id,reason_code,idempotency_key,authorize):
        self._valid(actor_id,reason_code,idempotency_key)
        payload=digest(dict(operation='notify',id=preparation_id,manifest=manifest_digest,actor=actor_id,reason=reason_code))
        with self.factory.begin() as session:
            fresh=self._lock(session,authorize)
            replay=self._replay(session,idempotency_key,payload)
            if replay is not None:
                fresh()
                return replay
            self._mode()
            row=self._preparation(session,preparation_id,actor_id)
            self._current(session,row,manifest_digest)
            self.outbox.enqueue(session,preparation_id=row.id,manifest_digest=row.manifest_digest,
                expected_events=row.manifest['alerts'],actor_id=actor_id,reason_code=reason_code,now=self.clock())
            result=self._command(session,row,key=idempotency_key,payload=payload,actor_id=actor_id,reason_code=reason_code,operation='notified')
            fresh()
            return result

    def confirm(self,*,preparation_id,manifest_digest,no_unregistered_payments,notice_received,
                actor_id,reason_code,idempotency_key,authorize):
        deadline = time.monotonic() + 20
        self._valid(actor_id,reason_code,idempotency_key)
        if no_unregistered_payments is not True or notice_received is not True:
            reject('HANDOVER_OWNER_CONFIRMATION_REQUIRED',422)
        payload=digest(dict(operation='confirm',id=preparation_id,manifest=manifest_digest,actor=actor_id,
            reason=reason_code,no_unregistered_payments=True,notice_received=True))
        with self.factory.begin() as session:
            fresh=self._lock(session,authorize)
            replay=self._replay(session,idempotency_key,payload)
            fresh()
            if replay is not None:
                return replay
            self._mode()
            row=self._preparation(session,preparation_id,actor_id)
            self._current(session,row,manifest_digest)
            self.outbox.require_delivered(session,manifest_digest=manifest_digest)
            if not self.monitor.external_delivery_configured:
                reject('HANDOVER_ALERTS_NOT_CONFIGURED',503)
        def complete(session):
            fresh=self._lock(session,authorize)
            replay=self._replay(session,idempotency_key,payload)
            if replay is not None:
                fresh()
                return replay
            if time.monotonic() >= deadline:
                _proof_unavailable('HANDOVER_PROOF_DEADLINE')
            self._mode()
            row=self._preparation(session,preparation_id,actor_id)
            self._current(session,row,manifest_digest)
            self.outbox.require_delivered(session,manifest_digest=manifest_digest)
            if not self.monitor.external_delivery_configured:
                reject('HANDOVER_ALERTS_NOT_CONFIGURED',503)
            fresh()
            adopt_legacy_stop(session,factory=self.factory,actor_id=actor_id,reason_code=reason_code,
                manifest_digest=manifest_digest,now=self.clock())
            self.incidents.supersede_legacy_in_session(session,expected=row.manifest['incidents'],handover_id=row.id,
                manifest_digest=manifest_digest,actor_id=actor_id,reason_code=reason_code)
            result=self._command(session,row,key=idempotency_key,payload=payload,actor_id=actor_id,reason_code=reason_code,operation='confirmed')
            fresh()
            if time.monotonic() >= deadline:
                _proof_unavailable('HANDOVER_PROOF_DEADLINE')
            return result
        reason = 'HANDOVER_PROOF_DEADLINE'
        for attempt in range(21):
            if time.monotonic() >= deadline:
                break
            result=self.monitor.handover_review_once(on_review=complete)
            if result.get('complete'):
                return result['result']
            codes = result.get('codes')
            reason = codes[0] if isinstance(codes, list) and len(codes) == 1 and isinstance(codes[0], str) else 'HANDOVER_PROOF_REJECTED'
            if (result.get('status'), reason) not in _TRANSIENT_PROOFS:
                break
            if attempt == 20 or deadline - time.monotonic() < 1:
                break
            # Each full proof has returned and released its transaction and
            # monitor lock. Retry the original callback without refreshing auth.
            time.sleep(1)
        _proof_unavailable(reason)
