"""Exact original-event remediation with one actually delivered replacement notice."""
from datetime import datetime, timedelta, timezone
import hashlib
import json
import re
from sqlalchemy import and_, or_, select
from app.core.errors import AppError
from app.core.outbox import OutboxEvent, OutboxMessage, OutboxPublisher
from app.core.outbox_handover_models import (OutboxHandoverNotice, OutboxHandoverMember,
    OutboxHandoverReceipt, OutboxHandoverDisposition)
from app.modules.audit.writer import AuditWriter

SUMMARY_EVENT = 'wallet.handover.summary'
DISPOSITION = 'SUPERSEDED_BY_HANDOVER_NOTICE'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def _iso(value):
    if value is None:
        return None
    return (value if value.tzinfo else value.replace(tzinfo=timezone.utc)).isoformat()


def _reject(code):
    raise AppError(code=code, message=code, status_code=409)


class OutboxHandover:
    def __init__(self, factory, *, clock=None):
        self.factory = factory
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    @staticmethod
    def not_superseded_predicate():
        return ~select(OutboxHandoverDisposition.event_id).join(OutboxHandoverNotice,
            OutboxHandoverNotice.id == OutboxHandoverDisposition.notice_id).join(OutboxHandoverReceipt,
            OutboxHandoverReceipt.notice_id == OutboxHandoverNotice.id).where(
                OutboxHandoverDisposition.event_id == OutboxEvent.id,
                OutboxHandoverDisposition.disposition == DISPOSITION,
                OutboxHandoverDisposition.manifest_digest == OutboxHandoverNotice.manifest_digest,
                OutboxHandoverReceipt.transport == 'SMTP',
                OutboxHandoverReceipt.payload_digest == OutboxHandoverNotice.payload_digest).exists()

    @classmethod
    def unhealthy_predicate(cls, now):
        return and_(OutboxEvent.topic == 'wallet.alert', cls.not_superseded_predicate(),
            or_(OutboxEvent.status == 'DEAD', and_(OutboxEvent.status.in_(('PENDING', 'FAILED', 'PROCESSING')),
                OutboxEvent.created_at <= now-timedelta(minutes=5))))

    @staticmethod
    def _snapshot(row):
        return dict(id=row.id, aggregate_id=row.aggregate_id, event_type=row.event_type,
            status=row.status, attempt_count=row.attempt_count, created_at=_iso(row.created_at),
            available_at=_iso(row.available_at), payload_digest=digest(row.payload),
            headers_digest=digest(row.event_headers), error_digest=digest(row.last_error))

    def capture(self, session, *, incident_ids):
        rows = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert',
            ~select(OutboxHandoverNotice.id).where(OutboxHandoverNotice.id == OutboxEvent.id).exists())
            .order_by(OutboxEvent.id).limit(10001).with_for_update()).all()
        if len(rows) > 10000:
            _reject('HANDOVER_ALERT_SET_TOO_LARGE')
        for row in rows:
            if row.status == 'PROCESSING' or row.locked_at is not None or row.locked_by is not None:
                _reject('HANDOVER_ALERT_LEASE_ACTIVE')
            if (row.aggregate_type != 'wallet_incident' or row.aggregate_id not in incident_ids
                    or row.event_type not in ('wallet.incident.opened', 'wallet.incident.escalated')
                    or row.status not in ('DEAD', 'PENDING', 'FAILED')
                    or not isinstance(row.payload, dict)
                    or set(row.payload) != {'incident_id', 'subject_id', 'code', 'severity'}
                    or row.payload['incident_id'] != row.aggregate_id or row.payload['subject_id'] != 'global'):
                _reject('HANDOVER_ALERT_SET_CONFLICT')
        return [self._snapshot(row) for row in rows]

    def enqueue(self, session, *, preparation_id, manifest_digest, expected_events, actor_id, reason_code, now):
        if re.fullmatch('[a-f0-9]{64}', manifest_digest) is None or not expected_events:
            _reject('HANDOVER_NOTICE_INVALID')
        existing = session.scalar(select(OutboxHandoverNotice).where(OutboxHandoverNotice.manifest_digest == manifest_digest))
        if existing is not None:
            return existing.id
        ids = sorted({row['aggregate_id'] for row in expected_events})
        if self.capture(session, incident_ids=ids) != expected_events:
            _reject('HANDOVER_ALERT_SET_CONFLICT')
        payload = dict(preparation_id=preparation_id, manifest_digest=manifest_digest,
            incident_count=len(ids), alert_count=len(expected_events), code='LEGACY_MONITOR_HANDOVER', severity='P0')
        notice_id = OutboxPublisher.enqueue(session, topic='wallet.alert', event_type=SUMMARY_EVENT,
            aggregate_type='wallet_handover', aggregate_id=preparation_id, payload=payload, now=now)
        session.add(OutboxHandoverNotice(id=notice_id, preparation_id=preparation_id,
            manifest_digest=manifest_digest, payload_digest=digest(payload), actor_id=actor_id,
            reason_code=reason_code, created_at=now))
        for row in expected_events:
            if session.get(OutboxHandoverMember, row['id']) is not None:
                _reject('HANDOVER_ALERT_ALREADY_RESERVED')
            session.add(OutboxHandoverMember(event_id=row['id'], notice_id=notice_id,
                original_snapshot=row, manifest_digest=manifest_digest, created_at=now))
        AuditWriter(self.factory, now_factory=self.clock).record_in_session(session, actor_id=actor_id,
            subject_type='outbox_handover', subject_id=notice_id, action='outbox.handover_notice_queued',
            result='SUCCESS', reason_code=reason_code, trace_id=manifest_digest,
            after=dict(manifest_digest=manifest_digest, alert_count=len(expected_events)))
        session.flush()
        return notice_id

    def _validate_delivery(self, session, event, *, lock=False):
        if not isinstance(event, OutboxMessage):
            _reject('HANDOVER_NOTICE_EVENT_INVALID')
        row = session.get(OutboxEvent, event.id, with_for_update=lock)
        notice = session.get(OutboxHandoverNotice, event.id, with_for_update=lock)
        if (row is None or notice is None or row.event_type != SUMMARY_EVENT or row.topic != 'wallet.alert'
                or row.aggregate_type != 'wallet_handover' or row.aggregate_id != notice.preparation_id
                or any(getattr(row, key) != getattr(event, key) for key in ('topic', 'event_type', 'aggregate_type', 'aggregate_id', 'payload'))
                or digest(row.payload) != notice.payload_digest):
            _reject('HANDOVER_NOTICE_EVENT_CONFLICT')
        receipt = session.get(OutboxHandoverReceipt, event.id)
        if receipt is not None and (receipt.transport != 'SMTP' or receipt.payload_digest != notice.payload_digest):
            _reject('HANDOVER_NOTICE_RECEIPT_CONFLICT')
        return row, notice, receipt

    def prepare_delivery(self, event):
        with self.factory() as session:
            row, _, receipt = self._validate_delivery(session, event)
            return None if receipt else dict(row.payload, event_id=row.id)

    def record_smtp_delivery(self, event):
        """Only the trusted sender calls this after SMTP acceptance; never on failure."""
        with self.factory.begin() as session:
            row, notice, receipt = self._validate_delivery(session, event, lock=True)
            if receipt is not None:
                return
            members = session.scalars(select(OutboxHandoverMember).where(
                OutboxHandoverMember.notice_id == notice.id).order_by(OutboxHandoverMember.event_id)).all()
            if not members or len(members) != row.payload['alert_count']:
                _reject('HANDOVER_NOTICE_MEMBERS_CONFLICT')
            now = self.clock()
            for member in members:
                original = session.get(OutboxEvent, member.event_id, with_for_update=True)
                if (original is None or original.locked_at is not None or original.locked_by is not None
                        or self._snapshot(original) != member.original_snapshot):
                    _reject('HANDOVER_ALERT_SET_CONFLICT')
                session.add(OutboxHandoverDisposition(event_id=member.event_id, notice_id=notice.id,
                    manifest_digest=notice.manifest_digest, disposition=DISPOSITION, actor_id=notice.actor_id,
                    reason_code=notice.reason_code, created_at=now))
            session.add(OutboxHandoverReceipt(notice_id=notice.id, payload_digest=notice.payload_digest,
                transport='SMTP', created_at=now))
            AuditWriter(self.factory, now_factory=self.clock).record_in_session(session, actor_id=notice.actor_id,
                subject_type='outbox_handover', subject_id=notice.id, action='outbox.handover_notice_delivered',
                result='SUCCESS', reason_code=notice.reason_code, trace_id=notice.manifest_digest,
                after=dict(disposition=DISPOSITION, alert_count=len(members)))
            OutboxPublisher.enqueue(session, topic='wallet', event_type='outbox.handover_notice_delivered',
                aggregate_type='outbox_handover', aggregate_id=notice.id,
                payload=dict(manifest_digest=notice.manifest_digest, alert_count=len(members)), now=now)

    def notice_status(self, session, *, manifest_digest):
        notice = session.scalar(select(OutboxHandoverNotice).where(OutboxHandoverNotice.manifest_digest == manifest_digest))
        if notice is None:
            return None, False
        receipt = session.get(OutboxHandoverReceipt, notice.id)
        return notice.id, bool(receipt and receipt.transport == 'SMTP' and receipt.payload_digest == notice.payload_digest)

    def require_delivered(self, session, *, manifest_digest):
        id, delivered = self.notice_status(session, manifest_digest=manifest_digest)
        if not delivered:
            _reject('HANDOVER_NOTICE_NOT_DELIVERED')
        return id
