"""Read-only wallet projections. Callers must enforce finance/audit authorization."""
from copy import deepcopy
from datetime import datetime, timezone

from sqlalchemy import select

from app.integrations.tron.finality import NETWORK, POLICY
from app.integrations.tron.reader import USDT_CONTRACT
from app.modules.wallet.manual_payout_models import ManualPayoutCandidate, ManualPayoutEvent, ManualPayoutOrder, ManualPayoutQuote
from app.modules.wallet.models import WalletLedgerTransaction
from app.modules.wallet.receipt_models import DepositReceipt, DepositReceiptAnomaly


def _iso(value):
    return (value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)).isoformat()


class WalletFinanceQuery:
    def __init__(self, factory):
        self.factory = factory

    def chain_link(self, txid, log_index):
        with self.factory() as session:
            row = session.scalar(select(DepositReceipt).where(DepositReceipt.network == NETWORK,
                DepositReceipt.contract == USDT_CONTRACT, DepositReceipt.txid == txid.lower(), DepositReceipt.log_index == log_index))
            if row is not None:
                conflict = session.scalar(select(DepositReceiptAnomaly.id).where(DepositReceiptAnomaly.receipt_id == row.id).limit(1))
                verified = row.evidence_policy == POLICY and row.reason_code not in {'INVALID_ASSET_EVIDENCE', 'INCONSISTENT_EVIDENCE'}
                return dict(kind='DEPOSIT', record_id=row.id, ledger_status=row.status, user_id=row.user_id,
                    ledger_transaction_id=row.ledger_transaction_id, intent_id=row.intent_id, reason_code=row.reason_code,
                    evidence_status='CONFLICT' if conflict else 'VERIFIED' if verified else 'UNVERIFIED')
            event = session.scalar(select(ManualPayoutEvent).where(ManualPayoutEvent.network == NETWORK,
                ManualPayoutEvent.contract == USDT_CONTRACT, ManualPayoutEvent.txid == txid.lower(), ManualPayoutEvent.log_index == log_index))
            if event is None:
                return None
            order = session.get(ManualPayoutOrder, event.order_id)
            transaction = session.scalar(select(WalletLedgerTransaction.id).where(
                WalletLedgerTransaction.scope == 'wallet.manual_settle', WalletLedgerTransaction.idempotency_key == event.order_id))
            return dict(kind='PAYOUT', record_id=event.order_id, ledger_status=order.status, user_id=order.user_id,
                ledger_transaction_id=transaction, intent_id=None, reason_code='MANUAL_PAYOUT_SETTLED', evidence_status='VERIFIED')

    @staticmethod
    def _order(session, row):
        settlement = session.scalar(select(ManualPayoutEvent.txid).where(ManualPayoutEvent.order_id == row.id))
        return dict(id=row.id, user_id=row.user_id, quote_id=row.quote_id, amount=format(row.amount, '.6f'),
            status=row.status, digest=row.digest, candidate_txid=row.candidate_txid, settlement_txid=settlement,
            review_reason=row.review_reason, claimed_by=row.claimed_by,
            claimed_at=_iso(row.claimed_at) if row.claimed_at else None, created_at=_iso(row.created_at))

    def payout(self, order_id):
        with self.factory() as session:
            row = session.get(ManualPayoutOrder, order_id)
            if row is None:
                return None
            quote = session.get(ManualPayoutQuote, row.quote_id)
            candidates = [dict(txid=c.txid, actor_id=c.actor_id, reason_code=c.reason_code, created_at=_iso(c.created_at))
                for c in session.scalars(select(ManualPayoutCandidate).where(ManualPayoutCandidate.order_id == row.id)
                    .order_by(ManualPayoutCandidate.created_at, ManualPayoutCandidate.id))]
            if row.candidate_txid and not any(c['txid'] == row.candidate_txid for c in candidates):
                candidates.insert(0, dict(txid=row.candidate_txid, actor_id=None, reason_code='LEGACY_ORIGINAL_LOCATOR', created_at=None))
            return self._order(session, row) | {'snapshot': deepcopy(quote.snapshot), 'candidates': candidates}

    def payouts(self, *, limit=50, cursor=None):
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError('invalid page size')
        statement = select(ManualPayoutOrder)
        if cursor:
            try:
                when, identifier = cursor.split('|', 1)
                when = datetime.fromisoformat(when)
                if when.tzinfo is None or not identifier or len(identifier) > 36:
                    raise ValueError()
            except (ValueError, AttributeError):
                raise ValueError('invalid cursor') from None
            statement = statement.where((ManualPayoutOrder.created_at < when) |
                ((ManualPayoutOrder.created_at == when) & (ManualPayoutOrder.id < identifier)))
        with self.factory() as session:
            rows = session.scalars(statement.order_by(ManualPayoutOrder.created_at.desc(), ManualPayoutOrder.id.desc()).limit(limit+1)).all()
            page = rows[:limit]
            return {'items': [self._order(session, row) for row in page],
                'next_cursor': _iso(page[-1].created_at)+'|'+page[-1].id if len(rows) > limit else None}
