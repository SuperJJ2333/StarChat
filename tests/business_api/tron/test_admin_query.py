import importlib
import json
import sqlite3

import pytest

from app.integrations.tron.observer import Observer
from app.integrations.tron.reader import _encode_address


@pytest.fixture
def watch_db(tmp_path):
    path = tmp_path / 'observer.sqlite'
    Observer(path, None, 'fixture-only', now_ms=lambda: 1000, start_ms=0)
    with sqlite3.connect(path) as db:
        for index, amount in enumerate([1, 10**40 + 123456, 9000000]):
            event = dict(txid=str(index + 1) * 64, log_index=0, timestamp_ms=100,
                         amount_units=amount, block_number=20,
                         from_address=_encode_address(bytes.fromhex('41' + '11' * 20)),
                         to_address=_encode_address(bytes.fromhex('41' + '22' * 20)))
            db.execute('INSERT INTO events VALUES (?,?,?,?,?,?,?,?)',
                       (event['txid'], 0, json.dumps(event), 100, str(amount),
                        str(amount if index != 2 else -amount),
                        'INFLOW' if index != 2 else 'UNMATCHED_OUTFLOW', 'HISTORICAL'))
        db.execute("INSERT INTO runs VALUES (NULL,1000,900,'OK',NULL)")
        db.execute("INSERT INTO observations VALUES (NULL,1000,900,20,900,'1234567',1,'SOURCE_MATCHED','0')")
        db.execute('UPDATE observer_state SET checkpoint_ms=900')
    return path


def query(path):
    module = importlib.import_module('app.integrations.tron.admin_query')
    return module.ChainWatchQuery(path, now_ms=lambda: 2000)


def test_exact_amounts_stable_pagination_filter_and_detail(watch_db):
    service = query(watch_db)
    page = service.transactions(limit=1, offset=0)
    assert page['total'] == 3
    assert page['items'][0]['txid'] == '3' * 64
    assert page['items'][0]['amount'] == '9.000000'
    item = service.transactions(limit=1, offset=1)['items'][0]
    assert item['amount'] == '10000000000000000000000000000000000.123456'
    assert item['user_attribution'] == 'UNVERIFIED'
    assert item['ledger_status'] == 'NOT_EVALUATED'
    assert service.detail('1' * 64, 0)['amount'] == '0.000001'
    assert service.detail('1' * 64, 0)['from_address'] == _encode_address(bytes.fromhex('41' + '11' * 20))
    assert 'from_address' not in page['items'][0]
    assert service.transactions(direction='INFLOW', start_ms=100, end_ms=100)['total'] == 2
    assert service.transactions(txid='2' * 64)['total'] == 1
    assert service.transactions(start_ms=101)['total'] == 0
    assert service.detail('4' * 64, 0) is None


def test_summary_coverage_is_not_independent_reconciliation(watch_db):
    result = query(watch_db).summary()
    assert result['watch_only'] is True
    assert result['financial_writes_enabled'] is False
    assert result['source'] == 'TRONGRID_SINGLE_SOURCE'
    assert result['coverage_start_ms'] == 0
    assert result['checkpoint_ms'] == 900
    assert result['last_success_ms'] == 1000
    assert result['lag_ms'] == 1100
    assert result['balance'] == '1.234567'
    assert result['independent_verification'] is False


def test_snapshot_pagination_excludes_late_backfill(watch_db):
    service = query(watch_db)
    first = service.transactions(limit=1)
    with sqlite3.connect(watch_db) as db:
        row = db.execute("SELECT * FROM events WHERE txid=?", ('1' * 64,)).fetchone()
        payload = json.loads(row[2])
        payload['txid'] = 'f' * 64
        db.execute('INSERT INTO events VALUES (?,?,?,?,?,?,?,?)',
                   (payload['txid'], row[1], json.dumps(payload), *row[3:]))
    second = service.transactions(limit=1, offset=1, snapshot=first['snapshot'])
    assert second['items'][0]['txid'] == '2' * 64
    assert second['total'] == 3
    assert second['snapshot'] == first['snapshot']
    assert service.transactions()['total'] == 4


def test_reader_does_not_mutate_observer_database(watch_db, monkeypatch):
    before = watch_db.read_bytes()
    original = sqlite3.connect
    connections = []

    def checked_connect(database, **kwargs):
        assert database.endswith('?mode=ro')
        assert kwargs['uri'] is True
        connection = original(database, **kwargs)
        with pytest.raises(sqlite3.OperationalError, match='readonly'):
            connection.execute('DELETE FROM events')
        connection.rollback()
        connections.append(database)
        return connection

    monkeypatch.setattr(sqlite3, 'connect', checked_connect)
    service = query(watch_db)
    service.summary()
    service.transactions()
    service.detail('1' * 64, 0)
    assert watch_db.read_bytes() == before
    assert len(connections) == 3


@pytest.mark.parametrize('kind', ['missing', 'corrupt', 'schema', 'payload', 'amount', 'address'])
def test_unavailable_is_sanitized_and_never_creates_database(watch_db, kind):
    path = watch_db
    if kind == 'missing':
        path = watch_db.parent / 'absent.sqlite'
    elif kind == 'corrupt':
        path.write_bytes(b'not a database')
    else:
        with sqlite3.connect(path) as db:
            if kind == 'schema':
                db.execute('DROP TABLE events')
            elif kind == 'payload':
                db.execute("UPDATE events SET payload='[]'")
            elif kind == 'amount':
                db.execute("UPDATE events SET amount_units='1.2'")
            else:
                row = db.execute('SELECT payload FROM events LIMIT 1').fetchone()
                event = json.loads(row[0])
                event['from_address'] = 'invalid-address'
                db.execute('UPDATE events SET payload=? WHERE txid=?', (json.dumps(event), event['txid']))
    module = importlib.import_module('app.integrations.tron.admin_query')
    with pytest.raises(module.ChainWatchUnavailable, match='CHAIN_WATCH_UNAVAILABLE'):
        query(path).transactions()
    if kind == 'missing':
        assert not path.exists()
