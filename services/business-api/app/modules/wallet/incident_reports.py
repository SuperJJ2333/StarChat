"""Read-only incident pages and persisted, explicitly linked evidence."""
import base64
from datetime import datetime, timezone, timedelta
import hashlib
import hmac
import json
import re

from sqlalchemy import select
from app.core.errors import AppError
from app.modules.audit.models import AuditEvent
from app.modules.identity.models import User
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.incidents import _dto, _aware
from app.modules.wallet.models import Withdrawal
from app.modules.wallet import binding_models, funding_models  # noqa: F401
from app.modules.wallet.receipt_models import DepositReceipt
from app.modules.wallet.manual_payout_models import ManualPayoutOrder


def invalid(code='WALLET_INCIDENT_QUERY_INVALID', status=422):
    raise AppError(code=code, message=code, status_code=status)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), default=str).encode()).hexdigest()


class WalletIncidentReports:
    def __init__(self, factory, *, cursor_secret, clock=None):
        self.factory, self.secret = factory, cursor_secret.encode()
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    def _encode(self, value):
        payload = base64.urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).decode().rstrip('=')
        signature = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
        return payload+'.'+signature

    def _decode(self, value):
        try:
            payload, signature = value.split('.')
            if not hmac.compare_digest(signature, hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()):
                invalid()
            decoded = json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
            if set(decoded) != {'filter', 'snapshot', 'last', 'expires'}:
                invalid()
            if self.clock().timestamp() >= decoded['expires']:
                invalid('WALLET_INCIDENT_CURSOR_EXPIRED', 409)
            return decoded
        except (ValueError, TypeError, KeyError, UnicodeDecodeError):
            invalid()

    def list(self, *, limit=50, cursor=None, status=None, severity=None, code=None, sort='opened_desc', condition_active=None):
        def values(value):
            return sorted(set([value] if isinstance(value, str) else value or []))
        status, severity, code = values(status), values(severity), values(code)
        if (type(limit) is not int or not 1 <= limit <= 100 or sort not in {'opened_desc', 'opened_asc', 'updated_desc'}
                or set(status)-{'OPEN', 'ACKNOWLEDGED', 'RESOLVED'} or set(severity)-{'P0', 'P1'}
                or len(code)>50 or any(not isinstance(c, str) or re.fullmatch('[A-Z][A-Z0-9_]{0,99}', c) is None for c in code)
                or condition_active is not None and type(condition_active) is not bool
                or cursor is not None and (not isinstance(cursor, str) or len(cursor)>2048)):
            invalid()
        filters = dict(status=status, severity=severity, code=code, sort=sort, condition_active=condition_active)
        filter_digest = digest(filters)
        decoded = self._decode(cursor) if cursor else None
        if decoded and decoded['filter'] != filter_digest:
            invalid('WALLET_INCIDENT_CURSOR_FILTER_CONFLICT', 409)
        clauses = []
        for column, selected in ((WalletIncident.status, status), (WalletIncident.severity, severity), (WalletIncident.code, code)):
            if selected:
                clauses.append(column.in_(selected))
        if condition_active is not None:
            clauses.append(WalletIncident.condition_active.is_(condition_active))
        column = WalletIncident.last_seen_at if sort == 'updated_desc' else WalletIncident.opened_at
        ascending = sort == 'opened_asc'
        with self.factory() as session:
            # Both signature and page must describe one database snapshot.
            if session.bind.dialect.name == 'postgresql':
                session.connection(execution_options={'isolation_level': 'REPEATABLE READ'})
            versions = session.execute(select(WalletIncident.id, WalletIncident.version, column,
                WalletIncident.status, WalletIncident.severity, WalletIncident.condition_active)
                .where(*clauses).order_by(WalletIncident.id)).all()
            snapshot = digest([[row[0], row[1], _aware(row[2]).isoformat(), *row[3:]] for row in versions])
            if decoded and decoded['snapshot'] != snapshot:
                invalid('WALLET_INCIDENT_SNAPSHOT_CHANGED', 409)
            query = select(WalletIncident).where(*clauses)
            if decoded:
                try:
                    at, identifier = decoded['last']
                    at = datetime.fromisoformat(at)
                except (TypeError, ValueError):
                    invalid()
                query = query.where((column>at) | ((column==at)&(WalletIncident.id>identifier)) if ascending
                    else (column<at) | ((column==at)&(WalletIncident.id<identifier)))
            query = query.order_by(column.asc(), WalletIncident.id.asc()) if ascending else query.order_by(column.desc(), WalletIncident.id.desc())
            rows = list(session.scalars(query.limit(limit+1)))
            next_cursor = None
            if len(rows)>limit:
                last = rows[limit-1]
                next_cursor = self._encode(dict(filter=filter_digest, snapshot=snapshot,
                    last=[_aware(getattr(last, column.key)).isoformat(), last.id],
                    expires=decoded['expires'] if decoded else (self.clock()+timedelta(minutes=10)).timestamp()))
            return dict(items=[_dto(row) for row in rows[:limit]], next_cursor=next_cursor, total=len(versions), snapshot=snapshot)

    def detail(self, incident_id):
        with self.factory() as session:
            if session.bind.dialect.name == 'postgresql':
                session.connection(execution_options={'isolation_level': 'REPEATABLE READ'})
            row = session.get(WalletIncident, incident_id)
            if row is None:
                invalid('WALLET_INCIDENT_NOT_FOUND', 404)
            events = list(session.scalars(select(AuditEvent).where(AuditEvent.subject_type=='wallet_incident',
                AuditEvent.subject_id==row.id).order_by(AuditEvent.created_at.desc(), AuditEvent.id.desc()).limit(201)))
            timeline = []
            linked = {'WITHDRAWAL': set(), 'DEPOSIT_RECEIPT': set(), 'MANUAL_PAYOUT': set(), 'USER': set()}
            if row.subject_id != 'global' and row.code in {'WITHDRAWAL_UNCERTAIN', 'WITHDRAWAL_UNKNOWN'}:
                linked['WITHDRAWAL'].add(row.subject_id)
            for event in reversed(events[:200]):
                data = event.after_data if isinstance(event.after_data, dict) else {}
                safe_state = dict(status=data.get('status') if data.get('status') in ('OPEN','ACKNOWLEDGED','RESOLVED') else None,
                    generation=data.get('generation') if type(data.get('generation')) is int else None,
                    version=data.get('version') if type(data.get('version')) is int else None,
                    condition_active=data.get('condition_active') if type(data.get('condition_active')) is bool else None)
                timeline.append(dict(id=event.id, created_at=_aware(event.created_at).isoformat(), action=event.action,
                    actor_id=event.actor_id, reason_code=event.reason_code, result=event.result,
                    **safe_state))
                for field, kind in (('withdrawal_id','WITHDRAWAL'),('receipt_id','DEPOSIT_RECEIPT'),('order_id','MANUAL_PAYOUT'),('user_id','USER')):
                    value=data.get(field)
                    if isinstance(value,str) and 1<=len(value)<=36:
                        linked[kind].add(value)
            records=[]
            for kind, model in (('WITHDRAWAL',Withdrawal),('DEPOSIT_RECEIPT',DepositReceipt),('MANUAL_PAYOUT',ManualPayoutOrder),('USER',User)):
                if not linked[kind]:
                    continue
                for identifier in session.scalars(select(model.id).where(model.id.in_(sorted(linked[kind]))).order_by(model.id)):
                    records.append(dict(kind=kind,id=identifier,relation='EXPLICIT_INCIDENT_LINK'))
            return dict(_dto(row),timeline=timeline,timeline_has_more=len(events)>200,related_records=records)
