"""Public, read-only evidence projection for cross-ledger reporting."""
from sqlalchemy import String, cast, literal, select

from app.modules.ledger.models import LedgerEntry, LedgerTransaction


def report_entries_before(end):
    """Return a composable SELECT; caller owns snapshot and evidence bound."""
    entry, transaction = LedgerEntry, LedgerTransaction
    return select(
        literal('ledger').label('source'), entry.id.label('id'),
        entry.transaction_id.label('transaction_id'), entry.account_id.label('account'),
        entry.asset.label('asset'), cast(entry.amount, String).label('amount'),
        entry.created_at.label('created_at'), transaction.reason_code.label('reason_code'),
        transaction.scope.label('scope'),
    ).outerjoin(transaction, entry.transaction_id == transaction.id).where(entry.created_at < end)
