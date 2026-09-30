"""The void gate must reject incomplete or changing single-source observations."""
import hashlib
import json
import sqlite3
from datetime import datetime, timezone

import pytest

from app.integrations.tron.admin_query import ChainWatchUnavailable, PayoutVoidEvidence


def fixture_database(path, now_ms, official, *, start_ms=None, outflow=None):
    identity = hashlib.sha256(('tron-mainnet-usdt:' + official).encode()).hexdigest()
    with sqlite3.connect(path) as db:
        db.executescript('''
            CREATE TABLE observer_state(singleton INTEGER, identity TEXT, start_ms INTEGER,
                live_started_ms INTEGER, checkpoint_ms INTEGER);
            CREATE TABLE observations(id INTEGER PRIMARY KEY, heartbeat_ms INTEGER,
                checkpoint_ms INTEGER, solid_block INTEGER, solid_timestamp_ms INTEGER,
                balance_units TEXT, stable_balance INTEGER, reconciliation TEXT, difference_units TEXT);
            CREATE TABLE runs(id INTEGER PRIMARY KEY, heartbeat_ms INTEGER, checkpoint_ms INTEGER,
                status TEXT, error_code TEXT);
            CREATE TABLE events(txid TEXT, log_index INTEGER, payload TEXT, timestamp_ms INTEGER,
                amount_units TEXT, net_units TEXT, classification TEXT, era TEXT);
        ''')
        db.execute('INSERT INTO observer_state VALUES (1,?,?,?,?)', (identity, start_ms or now_ms-60000, now_ms-60000, now_ms))
        db.execute("INSERT INTO observations VALUES (1,?,?,1,?,'0',1,'SOURCE_MATCHED','0')", (now_ms, now_ms, now_ms))
        db.execute("INSERT INTO runs VALUES (1,?,?,'OK',NULL)", (now_ms, now_ms))
        if outflow:
            payload = dict(txid='a'*64, log_index=0, timestamp_ms=now_ms-1000, amount_units=1000000,
                block_number=1, from_address=official, to_address=outflow)
            db.execute("INSERT INTO events VALUES (?,0,?,?,?,'-1000000','UNMATCHED_OUTFLOW','LIVE')",
                ('a'*64, json.dumps(payload), now_ms-1000, '1000000'))


def test_void_evidence_checks_coverage_outflow_and_identity(tmp_path):
    now_ms = 1_800_000_000_000
    official, target = 'official', 'target'
    path = tmp_path/'observer.sqlite3'
    fixture_database(path, now_ms, official, outflow=target)
    query = PayoutVoidEvidence(path, official_address=official, now_ms=lambda: now_ms)
    claim = datetime.fromtimestamp((now_ms-30000)/1000, timezone.utc)
    evidence = query.observe(claimed_at=claim, target_address=target, amount_units=1000000)
    assert evidence['matching_outflows'] == 1
    assert evidence['suspicious_outflows'] == 0
    assert query.verify(evidence) is True
    with sqlite3.connect(path) as db:
        db.execute('UPDATE observer_state SET identity=?', ('changed',))
    assert query.verify(evidence) is False


def test_void_evidence_rejects_uncovered_claim(tmp_path):
    now_ms = 1_800_000_000_000
    path = tmp_path/'observer.sqlite3'
    fixture_database(path, now_ms, 'official', start_ms=now_ms-1000)
    query = PayoutVoidEvidence(path, official_address='official', now_ms=lambda: now_ms)
    with pytest.raises(ChainWatchUnavailable):
        query.observe(claimed_at=datetime.fromtimestamp((now_ms-30000)/1000, timezone.utc),
            target_address='target', amount_units=1000000)
