"""Public read-only transfer projections for other business modules."""
from sqlalchemy import exists, func, literal, select
from sqlalchemy.orm import aliased

from app.modules.ledger.models import LedgerEntry
from app.modules.transfer.models import ChatTransfer


class TransferReadProjection:
    @staticmethod
    def matching_transaction_ids(session, pattern):
        escrow = LedgerEntry
        return select(escrow.transaction_id).join(
            ChatTransfer, func.substr(escrow.account_id, 26) == ChatTransfer.id).where(
            ChatTransfer.note.ilike(pattern, escape="\\"))

    @staticmethod
    def for_transactions(session, transaction_ids):
        if not transaction_ids:
            return {}
        rows = session.execute(select(LedgerEntry.transaction_id, LedgerEntry.account_id).where(
            LedgerEntry.transaction_id.in_(transaction_ids),
            LedgerEntry.account_id.like("PLATFORM_TRANSFER_ESCROW:%"))).all()
        ids = {account.removeprefix("PLATFORM_TRANSFER_ESCROW:") for _transaction_id, account in rows}
        transfers = {item.id: item for item in session.scalars(select(ChatTransfer).where(ChatTransfer.id.in_(ids))).all()} if ids else {}
        return {transaction_id: transfers.get(account.removeprefix("PLATFORM_TRANSFER_ESCROW:")) for transaction_id, account in rows}

    @staticmethod
    def search_clause(transaction_id_column, pattern):
        escrow = aliased(LedgerEntry)
        return exists(select(1).select_from(escrow).join(
            ChatTransfer, escrow.account_id == literal("PLATFORM_TRANSFER_ESCROW:") + ChatTransfer.id).where(
            escrow.transaction_id == transaction_id_column, ChatTransfer.note.ilike(pattern, escape="\\")).correlate(transaction_id_column.table))
