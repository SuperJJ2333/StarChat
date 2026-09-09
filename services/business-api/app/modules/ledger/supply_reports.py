"""Public read-only CAIBI supply and provenance queries. Never repairs history."""
import base64
import binascii
import json
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal

from sqlalchemy import and_, exists, func, or_, select
from sqlalchemy.orm import aliased

from app.modules.audit.models import AuditEvent
from app.modules.ledger.models import LedgerEntry, LedgerTransaction

ZERO = Decimal('0.00')


def point_supply(session, *, now=None):
    """One database statement gives all accounting facts the invariant consumes.

    Stream scalar rows to avoid ORM select-in reads or floating-point SQL sums
    on SQLite. PostgreSQL returns each NUMERIC as Decimal, too.
    """
    now = now or datetime.now(timezone.utc)
    original = aliased(LedgerTransaction)
    has_original = exists(select(original.id).where(
        original.id == LedgerTransaction.reversal_of_id, original.asset == 'CAIBI'))
    has_audit = exists(select(AuditEvent.id).where(
        AuditEvent.subject_type == 'ledger_transaction', AuditEvent.subject_id == LedgerTransaction.id))
    statement = select(
        LedgerEntry.transaction_id, LedgerEntry.account_id, LedgerEntry.amount,
        LedgerTransaction.id, LedgerTransaction.asset, LedgerTransaction.reversal_of_id,
        has_original, has_audit,
    ).outerjoin(LedgerTransaction, LedgerTransaction.id == LedgerEntry.transaction_id).where(
        LedgerEntry.asset == 'CAIBI')
    clearing, totals = defaultdict(lambda: ZERO), defaultdict(lambda: ZERO)
    holdings = fees = ZERO
    anomalies = set()
    for tx_id, account, amount, linked_id, asset, reversal, original_exists, audit_exists in session.execute(statement).yield_per(1000):
        totals[tx_id] += amount
        if account == 'PLATFORM_CLEARING':
            clearing[tx_id] += amount
        elif account == 'PLATFORM_FEE':
            fees += amount
        else:
            holdings += amount
        if linked_id is None:
            anomalies.add('missing_transaction')
        elif asset != 'CAIBI':
            anomalies.add('asset_mismatch')
        if reversal and not original_exists:
            anomalies.add('missing_reversal')
        if not audit_exists:
            anomalies.add('missing_audit')
    total = -sum(clearing.values(), ZERO)
    if total != holdings + fees or any(totals.values()):
        anomalies.add('unbalanced_ledger')
    return {
        'total': f'{total:.2f}',
        'issued': f'{-sum((v for v in clearing.values() if v < 0), ZERO):.2f}',
        'returned': f'{sum((v for v in clearing.values() if v > 0), ZERO):.2f}',
        'holdings': f'{holdings:.2f}', 'platform_fees': f'{fees:.2f}',
        'balanced': not anomalies, 'anomalies': sorted(anomalies), 'as_of': now.isoformat(),
    }


def _decode_cursor(cursor):
    try:
        timestamp, key = json.loads(base64.urlsafe_b64decode(cursor.encode('ascii')))
        stamp = datetime.fromisoformat(timestamp)
        if not isinstance(key, str) or not key or len(key) > 36:
            raise ValueError('invalid transaction key')
        return stamp, key
    except (ValueError, TypeError, UnicodeError, binascii.Error) as exc:
        raise ValueError('invalid report cursor') from exc


def _item(session, tx):
    delta = sum((entry.amount for entry in tx.entries
                 if entry.asset == 'CAIBI' and entry.account_id == 'PLATFORM_CLEARING'), ZERO)
    audits = session.scalars(select(AuditEvent).where(
        AuditEvent.subject_type == 'ledger_transaction', AuditEvent.subject_id == tx.id
    ).order_by(AuditEvent.created_at, AuditEvent.id)).all()
    anomalies = []
    if not audits:
        anomalies.append('missing_audit')
    if tx.reversal_of_id:
        original = session.get(LedgerTransaction, tx.reversal_of_id)
        if original is None or original.asset != 'CAIBI':
            anomalies.append('missing_reversal')
    if any(entry.asset != 'CAIBI' for entry in tx.entries) or sum((entry.amount for entry in tx.entries), ZERO):
        anomalies.append('unbalanced_ledger')
    item = {'id': tx.id, 'transaction_id': tx.id, 'created_at': tx.created_at.isoformat(),
            'kind': 'issued' if delta < 0 else 'returned', 'amount': f'{abs(delta):.2f}',
            'actor_id': tx.actor_id, 'reason_code': tx.reason_code, 'scope': tx.scope,
            'reversal_of_id': tx.reversal_of_id, 'audit_ids': [row.id for row in audits],
            'anomalies': anomalies}
    return item, audits


def issuance_page(session, *, limit=50, cursor=None, kind=None):
    if not 1 <= limit <= 100 or kind not in (None, 'issued', 'returned'):
        raise ValueError('invalid report filter')
    clearing = select(LedgerEntry.transaction_id.label('tx_id'), func.sum(LedgerEntry.amount).label('delta')).where(
        LedgerEntry.asset == 'CAIBI', LedgerEntry.account_id == 'PLATFORM_CLEARING'
    ).group_by(LedgerEntry.transaction_id).subquery()
    statement = select(LedgerTransaction).join(clearing, clearing.c.tx_id == LedgerTransaction.id).where(
        LedgerTransaction.asset == 'CAIBI', clearing.c.delta != 0)
    if kind:
        statement = statement.where(clearing.c.delta < 0 if kind == 'issued' else clearing.c.delta > 0)
    if cursor:
        stamp, key = _decode_cursor(cursor)
        statement = statement.where(or_(LedgerTransaction.created_at < stamp,
            and_(LedgerTransaction.created_at == stamp, LedgerTransaction.id < key)))
    rows = session.scalars(statement.order_by(LedgerTransaction.created_at.desc(), LedgerTransaction.id.desc()).limit(limit + 1)).all()
    next_cursor = None
    if len(rows) > limit:
        last = rows[limit - 1]
        next_cursor = base64.urlsafe_b64encode(json.dumps([last.created_at.isoformat(), last.id]).encode()).decode()
    return {'items': [_item(session, tx)[0] for tx in rows[:limit]], 'next_cursor': next_cursor}


def issuance_detail(session, transaction_id):
    tx = session.get(LedgerTransaction, transaction_id)
    if tx is None or tx.asset != 'CAIBI' or not sum((entry.amount for entry in tx.entries
            if entry.asset == 'CAIBI' and entry.account_id == 'PLATFORM_CLEARING'), ZERO):
        return None
    item, audits = _item(session, tx)
    return {**item, 'entries': [{'id': entry.id, 'account_id': entry.account_id,
            'asset': entry.asset, 'amount': f'{entry.amount:.2f}'} for entry in sorted(tx.entries, key=lambda row: row.id)],
        'audits': [{'id': row.id, 'actor_id': row.actor_id, 'action': row.action,
            'resource_type': row.subject_type, 'resource_id': row.subject_id, 'reason_code': row.reason_code,
            'created_at': row.created_at.isoformat()} for row in audits]}
