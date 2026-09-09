"""Bounded daily ledger previews, never a persisted or finalized close.

All pre-end entries are evidence, including opening balances. A single UNION
statement supplies a consistent database snapshot on PostgreSQL and SQLite.
Late/backdated commits can legitimately change the next preview and digest.
"""
import csv
import hashlib
import json
import re
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal, InvalidOperation, localcontext
from io import StringIO
from zoneinfo import ZoneInfo

from sqlalchemy import String, cast, literal, select, union_all

from app.modules.ledger.reporting import report_entries_before
from app.modules.wallet.models import WalletLedgerEntry, WalletLedgerTransaction

REPORT_TIMEZONE = ZoneInfo('Asia/Hong_Kong')
MAX_ENTRIES = 100_000


class ReportDataError(ValueError):
    """Stored evidence is invalid; distinguish it from a bad requested date."""


def _utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def _iso(value):
    return _utc(value).isoformat().replace('+00:00', 'Z')


def _money(value, asset):
    return format(value, '.2f' if asset == 'CAIBI' else '.6f')


class WalletReportService:
    def __init__(self, factory, *, max_entries=MAX_ENTRIES):
        if type(max_entries) is not int or not 1 <= max_entries <= MAX_ENTRIES:
            raise ValueError('invalid report evidence limit')
        self.factory = factory
        self.max_entries = max_entries

    def daily(self, day: date):
        if type(day) is not date or day > datetime.now(REPORT_TIMEZONE).date():
            raise ValueError('invalid report day')
        try:
            start = datetime.combine(day, time.min, REPORT_TIMEZONE).astimezone(timezone.utc)
            end = datetime.combine(day + timedelta(days=1), time.min, REPORT_TIMEZONE).astimezone(timezone.utc)
        except (OverflowError, ValueError) as exc:
            raise ValueError('invalid report day') from exc
        entry, transaction = WalletLedgerEntry, WalletLedgerTransaction
        wallet = select(
            literal('wallet').label('source'), entry.id.label('id'),
            entry.transaction_id.label('transaction_id'), entry.account_id.label('account'),
            entry.asset.label('asset'), cast(entry.amount, String).label('amount'),
            entry.created_at.label('created_at'), transaction.reason_code.label('reason_code'),
            transaction.scope.label('scope'),
        ).outerjoin(transaction, entry.transaction_id == transaction.id).where(entry.created_at < end)
        # LIMIT+1 is refusal detection, never a silently truncated response. Both
        # domains and all opening evidence are read by this one SQL statement.
        statement = union_all(report_entries_before(end), wallet).limit(self.max_entries + 1)
        with self.factory() as session:
            rows = session.execute(statement).mappings().all()
        if len(rows) > self.max_entries:
            raise OverflowError('report evidence limit exceeded')
        with localcontext() as context:
            context.prec = 60
            return self._build(day, start, end, rows)

    @staticmethod
    def _build(day, start, end, rows):
        entries, balances, transactions = [], {}, {}
        missing_metadata = False
        for row in sorted(rows, key=lambda r: (r['source'], r['id'])):
            asset, account = row['asset'], row['account']
            if asset not in {'CAIBI', 'USDT-TRC20'}:
                raise ReportDataError('unsupported report asset')
            try:
                amount = Decimal(row['amount'])
                quantum = Decimal('0.01') if asset == 'CAIBI' else Decimal('0.000001')
                if not amount.is_finite() or amount != amount.quantize(quantum):
                    raise ReportDataError('invalid report amount precision')
            except (InvalidOperation, TypeError) as exc:
                raise ReportDataError('invalid report amount') from exc
            at = _utc(row['created_at'])
            period = 'opening' if at < start else 'movement'
            amounts = balances.setdefault((asset, account), [Decimal(0), Decimal(0), Decimal(0)])
            if period == 'opening':
                amounts[0] += amount
            elif amount >= 0:
                amounts[1] += amount
            else:
                amounts[2] -= amount
            tx_key = (row['source'], row['transaction_id'], asset)
            transactions[tx_key] = transactions.get(tx_key, Decimal(0)) + amount
            missing_metadata |= row['reason_code'] is None or row['scope'] is None
            entries.append(dict(source=row['source'], id=row['id'], transaction_id=row['transaction_id'],
                                account=account, asset=asset, amount=_money(amount, asset),
                                created_at=_iso(at), reason_code=row['reason_code'], scope=row['scope'], period=period))
        accounts = [dict(asset=asset, account=account, opening=_money(o, asset),
                         increase=_money(i, asset), decrease=_money(d, asset), closing=_money(o+i-d, asset))
                    for (asset, account), (o, i, d) in sorted(balances.items())]
        imbalances = [dict(source=source, transaction_id=txid, asset=asset, amount=_money(amount, asset))
                      for (source, txid, asset), amount in sorted(transactions.items()) if amount != 0]
        report = dict(day=day.isoformat(), timezone='Asia/Hong_Kong', start=_iso(start), end=_iso(end),
                      finalized=False, accounts=accounts, entries=entries,
                      integrity=dict(balanced=not imbalances and not missing_metadata, entry_count=len(entries),
                                     transaction_count=len({(source, txid) for source, txid, asset in transactions}),
                                     imbalances=imbalances, missing_transaction_metadata=missing_metadata))
        report['digest'] = hashlib.sha256(json.dumps(report, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()
        return report


def _safe_text(value):
    text = '' if value is None else str(value)
    # Spreadsheet engines may ignore leading whitespace before formula markers.
    if text and (ord(text[0]) < 32 or text.lstrip().startswith(('=', '+', '-', '@'))):
        return "'" + text
    return text


def to_csv(report):
    """Export fixed sections; only validated decimal money bypasses text escaping."""
    output = StringIO(newline='')
    writer = csv.writer(output, lineterminator='\r\n')
    def write(values, money_columns=()):
        cells = []
        for index, value in enumerate(values):
            if index in money_columns and isinstance(value, str) and re.fullmatch(r'-?\d+\.\d{2}(?:\d{4})?', value):
                cells.append(value)
            else:
                cells.append(_safe_text(value))
        writer.writerow(cells)
    for name in ('day', 'timezone', 'start', 'end', 'finalized', 'digest'):
        write([name, str(report[name]).lower() if isinstance(report[name], bool) else report[name]])
    write(['integrity', json.dumps(report['integrity'], sort_keys=True, separators=(',', ':'))])
    write(['accounts', 'asset', 'account', 'opening', 'increase', 'decrease', 'closing'])
    for row in report['accounts']:
        write(['account'] + [row[k] for k in ('asset', 'account', 'opening', 'increase', 'decrease', 'closing')], (3, 4, 5, 6))
    columns = ('source', 'id', 'transaction_id', 'account', 'asset', 'amount', 'created_at', 'reason_code', 'scope', 'period')
    write(['entries', *columns])
    for row in report['entries']:
        write(['entry'] + [row[k] for k in columns], (6,))
    return output.getvalue()
