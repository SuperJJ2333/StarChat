"""Audited legacy ownership adoption with unchanged CAIBI liabilities."""
from datetime import datetime, timezone
from decimal import Decimal, localcontext
import hashlib
import json
from sqlalchemy import func, select
from app.core.errors import AppError
from app.core.outbox import OutboxPublisher
from app.modules.audit.writer import AuditWriter
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.ledger.reserve import lock_budget, caibi_liability
from app.modules.ledger.restriction_models import LedgerOutgoingRestriction
from app.modules.ledger.restrictions import restrict


def require_empty_history(session):
    reserve = lock_budget(session)
    if reserve is not None or any(session.scalar(select(func.count()).select_from(model))
            for model in (LedgerEntry, LedgerTransaction, LedgerOutgoingRestriction)):
        raise AppError(code='HANDOVER_LEDGER_HISTORY_PRESENT', message='HANDOVER_LEDGER_HISTORY_PRESENT', status_code=409)
    return dict(ledger_entries=0, ledger_transactions=0, ledger_restrictions=0, reserve=0)


def _invalid_history():
    raise AppError(code='HANDOVER_LEDGER_HISTORY_INVALID', message='HANDOVER_LEDGER_HISTORY_INVALID', status_code=409)


def _text(value, maximum):
    if (not isinstance(value, str) or not value.strip() or len(value) > maximum
            or any(ord(character) < 32 for character in value)):
        _invalid_history()
    return value


def _timestamp(value):
    if not isinstance(value, datetime):
        _invalid_history()
    return (value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)).isoformat()


def handover_history_snapshot(session):
    """Lock and bind complete CAIBI history; never discount redeemable liability.

    The original empty result is preserved. Nonempty history has a separate
    policy and commits every persisted transaction/entry column to its digest.
    Callers must compare this snapshot again in the final budget transaction.
    """
    reserve = lock_budget(session)
    if reserve is not None or session.scalar(select(func.count()).select_from(LedgerOutgoingRestriction)):
        raise AppError(code='HANDOVER_LEDGER_HISTORY_PRESENT', message='HANDOVER_LEDGER_HISTORY_PRESENT', status_code=409)
    transactions = list(session.execute(select(LedgerTransaction.__table__).order_by(LedgerTransaction.id)).mappings())
    entries = list(session.execute(select(LedgerEntry.__table__).order_by(LedgerEntry.id)).mappings())
    if not transactions and not entries:
        return dict(ledger_entries=0, ledger_transactions=0, ledger_restrictions=0, reserve=0)
    by_id = {row['id']: row for row in transactions}
    postings = {identifier: [] for identifier in by_id}
    canonical_transactions, canonical_entries = [], []
    keys = set()
    for row in transactions:
        if row['asset'] != 'CAIBI':
            _invalid_history()
        for name, maximum in (('id',36),('scope',80),('idempotency_key',128),('actor_id',36),('reason_code',100)):
            _text(row[name], maximum)
        key = (row['scope'], row['idempotency_key'])
        if key in keys:
            _invalid_history()
        keys.add(key)
        reversal = row['reversal_of_id']
        if reversal is not None and (reversal not in by_id or reversal == row['id']):
            _invalid_history()
        canonical_transactions.append(dict(row) | {'created_at': _timestamp(row['created_at'])})
    with localcontext() as context:
        context.prec = 100
        for row in entries:
            if row['transaction_id'] not in by_id or row['asset'] != 'CAIBI':
                _invalid_history()
            _text(row['id'],36)
            _text(row['account_id'],64)
            amount = row['amount']
            if not isinstance(amount, Decimal) or not amount.is_finite() or amount != amount.quantize(Decimal('0.01')):
                _invalid_history()
            postings[row['transaction_id']].append((row['account_id'],amount))
            canonical_entries.append(dict(row) | {'amount':format(amount,'.2f'), 'created_at':_timestamp(row['created_at'])})
        totals = {}
        for identifier, values in postings.items():
            if len(values) < 2 or sum((amount for _,amount in values), Decimal(0)) != 0:
                _invalid_history()
            by_account = {}
            for account, amount in values:
                by_account[account] = by_account.get(account, Decimal(0)) + amount
            totals[identifier] = by_account
        for identifier in postings:
            original = by_id[identifier]['reversal_of_id']
            if original is not None:
                accounts = totals[identifier].keys() | totals[original].keys()
                if any(totals[identifier].get(account, Decimal(0)) != -totals[original].get(account, Decimal(0))
                       for account in accounts):
                    _invalid_history()
            # Every reversal link must terminate; no fabricated circular history.
            visited = {identifier}
            reversal = by_id[identifier]['reversal_of_id']
            while reversal is not None:
                if reversal in visited:
                    _invalid_history()
                visited.add(reversal)
                reversal = by_id[reversal]['reversal_of_id']
        liability = caibi_liability(session)
        payload = dict(history_policy='CAIBI_HISTORY_V1',transactions=canonical_transactions,entries=canonical_entries)
        digest = hashlib.sha256(json.dumps(payload,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        return dict(ledger_entries=len(entries),ledger_transactions=len(transactions),ledger_restrictions=0,reserve=0,
            history_policy='CAIBI_HISTORY_V1',history_digest=digest,caibi_liability=format(liability,'.2f'))


def adopt_no_funds_legacy(session, *, factory, actor_id, reason_code, manifest_digest, now):
    history = handover_history_snapshot(session)
    epoch = restrict(session, actor_id=actor_id, reason_code=reason_code, scope='manual_tron')
    payload = dict(manifest_digest=manifest_digest, successor_scope='manual_tron', epoch=epoch, funds_paused=True,
        history=history)
    AuditWriter(factory, now_factory=lambda: now).record_in_session(session, actor_id=actor_id,
        subject_type='ledger_reserve', subject_id='global', action='ledger.legacy_stop_adopted',
        result='SUCCESS', reason_code=reason_code, trace_id=manifest_digest, after=payload)
    OutboxPublisher.enqueue(session, topic='ledger', event_type='ledger.legacy_stop_adopted',
        aggregate_type='ledger_reserve', aggregate_id='global', payload=payload, now=now)
    return epoch
