"""Read-only observer evidence. No user attribution or ledger authority."""
from contextlib import contextmanager
import json
from pathlib import Path
import re
import sqlite3
import time

from app.integrations.tron.reader import validate_tron_address


class ChainWatchUnavailable(Exception):
    """Sanitized failure for missing, inaccessible or malformed observation data."""


def _amount(value):
    if not isinstance(value, str) or not re.fullmatch(r'-?(0|[1-9][0-9]{0,77})', value):
        raise ValueError('invalid units')
    units = int(value)
    whole, fractional = divmod(abs(units), 1_000_000)
    return f'{"-" if units < 0 else ""}{whole}.{fractional:06d}'


def _nonnegative(value):
    if type(value) is not int or value < 0:
        raise ValueError('invalid integer')
    return value


class ChainWatchQuery:
    def __init__(self, database_path, *, now_ms=None):
        self.path = Path(database_path) if database_path else None
        self.now_ms = now_ms or (lambda: time.time_ns() // 1_000_000)

    @contextmanager
    def _read(self):
        connection = None
        try:
            if self.path is None:
                raise ValueError('unconfigured')
            connection = sqlite3.connect(self.path.resolve().as_uri() + '?mode=ro', uri=True, timeout=2)
            connection.row_factory = sqlite3.Row
            connection.execute('PRAGMA query_only=ON')
            connection.execute('BEGIN')
            yield connection
        except (OSError, sqlite3.Error, ValueError, TypeError, KeyError, IndexError, OverflowError):
            raise ChainWatchUnavailable('CHAIN_WATCH_UNAVAILABLE') from None
        finally:
            if connection is not None:
                connection.close()

    @staticmethod
    def _event(row, *, detail=False):
        event = json.loads(row['payload'])
        if not isinstance(event, dict):
            raise ValueError('invalid payload')
        if (event['txid'] != row['txid'] or event['log_index'] != row['log_index']
                or event['timestamp_ms'] != row['timestamp_ms']
                or str(event['amount_units']) != row['amount_units']
                or not re.fullmatch(r'[a-fA-F0-9]{64}', row['txid'])
                or row['classification'] not in ('INFLOW', 'UNMATCHED_OUTFLOW')
                or row['era'] not in ('HISTORICAL', 'LIVE')):
            raise ValueError('invalid evidence')
        _nonnegative(event['amount_units'])
        _nonnegative(row['log_index'])
        _nonnegative(row['timestamp_ms'])
        addresses = {key: validate_tron_address(event[key]) for key in ('from_address', 'to_address')}
        # Raw provider fields never leave this allowlist. Addresses are detail-only.
        result = dict(txid=row['txid'], log_index=row['log_index'],
                    timestamp_ms=row['timestamp_ms'], block_number=_nonnegative(event['block_number']),
                    amount=_amount(row['amount_units']), net_amount=_amount(row['net_units']),
                    direction=row['classification'], era=row['era'], asset='USDT', network='TRON',
                    user_attribution='UNVERIFIED', ledger_status='NOT_EVALUATED', watch_only=True)
        if detail:
            result.update(addresses)
        return result

    def transactions(self, *, limit=50, offset=0, direction=None, start_ms=None, end_ms=None, txid=None, snapshot=None):
        if not 1 <= limit <= 100 or offset < 0 or (start_ms is not None and end_ms is not None and start_ms > end_ms):
            raise ValueError('invalid pagination or range')
        if snapshot is not None and (type(snapshot) is not int or not 0 <= snapshot <= 9223372036854775807):
            raise ValueError('invalid snapshot')
        clauses, values = [], []
        for column, operator, value in [('classification', '=', direction), ('timestamp_ms', '>=', start_ms),
                                         ('timestamp_ms', '<=', end_ms), ('txid', '=', txid)]:
            if value is not None:
                clauses.append(f'{column}{operator}?')
                values.append(value)
        with self._read() as db:
            if snapshot is None:
                snapshot = db.execute('SELECT COALESCE(MAX(rowid),0) FROM events').fetchone()[0]
            clauses.append('rowid<=?')
            values.append(snapshot)
            where = ' WHERE ' + ' AND '.join(clauses)
            total = db.execute('SELECT COUNT(*) FROM events' + where, values).fetchone()[0]
            rows = db.execute('SELECT * FROM events' + where +
                              ' ORDER BY timestamp_ms DESC, txid DESC, log_index DESC LIMIT ? OFFSET ?',
                              [*values, limit, offset])
            return dict(items=[self._event(row) for row in rows], total=total, limit=limit, offset=offset, snapshot=snapshot)

    def detail(self, txid, log_index):
        with self._read() as db:
            row = db.execute('SELECT * FROM events WHERE txid=? AND log_index=?', (txid, log_index)).fetchone()
            return self._event(row, detail=True) if row else None

    def summary(self):
        with self._read() as db:
            state = db.execute('SELECT * FROM observer_state WHERE singleton=1').fetchone()
            run = db.execute('SELECT * FROM runs ORDER BY id DESC LIMIT 1').fetchone()
            observation = db.execute('SELECT * FROM observations ORDER BY id DESC LIMIT 1').fetchone()
            total = db.execute('SELECT COUNT(*) FROM events').fetchone()[0]
            checkpoint = _nonnegative(state['checkpoint_ms'])
            heartbeat = _nonnegative(run['heartbeat_ms']) if run else None
            success = _nonnegative(observation['heartbeat_ms']) if observation else None
            return dict(source='TRONGRID_SINGLE_SOURCE', network='TRON', asset='USDT', watch_only=True,
                        financial_writes_enabled=False, user_attribution='UNVERIFIED',
                        independent_verification=False, coverage_complete=False,
                        coverage_meaning='SOURCE_TRAVERSAL_ONLY',
                        coverage_start_ms=_nonnegative(state['start_ms']),
                        live_started_ms=_nonnegative(state['live_started_ms']), checkpoint_ms=checkpoint,
                        heartbeat_ms=heartbeat, last_success_ms=success,
                        lag_ms=max(0, self.now_ms() - checkpoint),
                        freshness_ms=None if success is None else max(0, self.now_ms() - success),
                        observer_status=('OK' if run['status'] == 'OK' else 'ERROR') if run else 'NOT_STARTED',
                        reconciliation=(observation['reconciliation'] if observation and observation['reconciliation']
                                        in ('SOURCE_MATCHED', 'BALANCE_DISCREPANCY') else 'RECONCILIATION_UNVERIFIED'),
                        balance=_amount(observation['balance_units']) if observation else None,
                        total=total)
