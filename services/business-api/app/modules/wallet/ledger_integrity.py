"""Read-only, exact ledger integrity over one streamed database snapshot."""
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, localcontext
from itertools import groupby

from sqlalchemy import String, cast, literal, select, union_all

from app.modules.ledger.reporting import report_entries_before
from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction
from app.modules.wallet.reporting import ReportDataError


class WalletLedgerIntegrityService:
    def __init__(self, factory):
        self.factory = factory

    def check(self, cutoff):
        if not isinstance(cutoff, datetime) or cutoff.tzinfo is None or cutoff.utcoffset() is None:
            raise ValueError('aware integrity cutoff required')
        cutoff = cutoff.astimezone(timezone.utc)
        entry, transaction = WalletLedgerEntry, WalletLedgerTransaction
        wallet = select(literal('wallet').label('source'), entry.id.label('id'),
            entry.transaction_id.label('transaction_id'), entry.account_id.label('account'),
            entry.asset.label('asset'), cast(entry.amount, String).label('amount'),
            entry.created_at.label('created_at'), transaction.reason_code.label('reason_code'),
            transaction.scope.label('scope')).outerjoin(transaction, entry.transaction_id == transaction.id)
        statement = union_all(report_entries_before(cutoff), wallet.where(entry.created_at < cutoff))
        statement = statement.order_by('source', 'transaction_id', 'asset', 'id').execution_options(yield_per=250)
        balanced, missing, count = True, False, 0
        with self.factory() as session:
            rows = session.execute(statement).mappings()
            try:
                for _, group in groupby(rows, key=lambda row: (row['source'], row['transaction_id'], row['asset'])):
                    # Python integer minor units keep sums exact at any volume.
                    total = 0
                    for row in group:
                        count += 1
                        missing |= not row['reason_code'] or not row['scope']
                        asset = row['asset']
                        if asset not in ('CAIBI', 'USDT-TRC20'):
                            raise ReportDataError('invalid ledger integrity evidence')
                        try:
                            with localcontext() as context:
                                context.prec = 100
                                value = Decimal(row['amount'])
                                scaled = value * (100 if asset == 'CAIBI' else 1000000)
                                if not scaled.is_finite() or scaled != scaled.to_integral_value():
                                    raise ReportDataError('invalid ledger integrity evidence')
                                total += int(scaled)
                        except (ValueError, TypeError, InvalidOperation) as exc:
                            raise ReportDataError('invalid ledger integrity evidence') from exc
                    balanced &= total == 0
            finally:
                rows.close()
        return dict(balanced=bool(balanced and not missing), missing_transaction_metadata=bool(missing), entry_count=count)
