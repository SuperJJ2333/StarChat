"""Public wallet-domain validation and durable SMTP acceptance receipts."""
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
import re

from sqlalchemy import text

from app.core.outbox import OutboxEvent, OutboxMessage
from app.modules.wallet.incident_models import WalletAlertReceipt, WalletIncident


class WalletAlertDeliveryError(RuntimeError):
    """Only constant local errors may reach retry diagnostics."""


@dataclass(frozen=True)
class WalletAlertEnvelope:
    event_id: str
    code: str
    severity: str


class WalletAlertDelivery:
    def __init__(self,factory):
        self.factory=factory

    @staticmethod
    def _validate(session,event,*,lock=False):
        if not isinstance(event,OutboxMessage) or not isinstance(event.payload,dict):
            raise WalletAlertDeliveryError('WALLET_ALERT_EVENT_INVALID')
        persisted=session.get(OutboxEvent,event.id,with_for_update=lock)
        if (persisted is None or persisted.topic!='wallet.alert' or persisted.aggregate_type!='wallet_incident'
                or persisted.event_type not in ('wallet.incident.opened','wallet.incident.reopened',
                    'wallet.incident.severity_changed','wallet.incident.escalated')
                or any(getattr(persisted,key)!=getattr(event,key) for key in ('topic','event_type','aggregate_type','aggregate_id','payload'))):
            raise WalletAlertDeliveryError('WALLET_ALERT_EVENT_CONFLICT')
        payload=persisted.payload
        if (not isinstance(payload,dict) or set(payload)!={'incident_id','subject_id','code','severity'}
                or not isinstance(payload['code'],str) or re.fullmatch('[A-Z][A-Z0-9_]{0,99}',payload['code']) is None
                or payload['severity'] not in ('P0','P1') or payload['incident_id']!=persisted.aggregate_id):
            raise WalletAlertDeliveryError('WALLET_ALERT_EVENT_INVALID')
        existing=session.get(WalletAlertReceipt,event.id)
        if existing:
            if existing.transport!='SMTP' or existing.incident_id!=persisted.aggregate_id or existing.payload!=payload:
                raise WalletAlertDeliveryError('WALLET_ALERT_RECEIPT_CONFLICT')
            # The incident can legitimately change after successful delivery.
            # Its immutable delivered event/receipt remain the replay authority.
            return persisted,existing
        incident=session.get(WalletIncident,persisted.aggregate_id,with_for_update=lock)
        # Severity is a historical fact in the immutable Outbox payload; the
        # incident may legitimately change severity while delivery is pending.
        if (incident is None or incident.severity not in ('P0','P1')
                or any(payload[key]!=getattr(incident,key) for key in ('subject_id','code'))):
            raise WalletAlertDeliveryError('WALLET_ALERT_INCIDENT_CONFLICT')
        return persisted,existing

    def prepare(self,event):
        with self.factory() as session:
            persisted,existing=self._validate(session,event)
            if existing: return None
            return WalletAlertEnvelope(persisted.id,persisted.payload['code'],persisted.payload['severity'])

    def record_smtp_delivery(self,event):
        """Call only after SMTP acceptance; commit failure can cause a duplicate email."""
        with self.factory.begin() as session:
            if session.get_bind().dialect.name=='sqlite':
                session.execute(text('BEGIN IMMEDIATE'))
            persisted,existing=self._validate(session,event,lock=True)
            if existing: return
            session.add(WalletAlertReceipt(event_id=persisted.id,incident_id=persisted.aggregate_id,
                transport='SMTP',payload=deepcopy(persisted.payload),created_at=datetime.now(timezone.utc)))
