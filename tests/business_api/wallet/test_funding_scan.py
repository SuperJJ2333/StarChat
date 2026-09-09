"""Durable intake tests use an isolated observer database, never chain access."""
from datetime import datetime, timedelta, timezone
from contextlib import closing
import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.modules.wallet.models import WalletControl


@pytest.fixture
def scan():
    from app.integrations.tron.funding_source import SQLiteFundingSource
    from app.modules.wallet.funding_scan import FundingScanService
    from app.modules.wallet import funding_scan_models, funding_models, binding_models  # noqa: F401
    from app.integrations.tron.observer import Observer
    from app.integrations.tron.message_signature import address_from_public_key
    from coincurve import PrivateKey
    folder = Path('docs/verification/artifacts/2026-09-07/manual-tron-funding/runtime/scan')
    folder.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(dir=folder) as temp:
        now = [datetime(2026, 9, 7, tzinfo=timezone.utc)]
        ms = int(now[0].timestamp()*1000)
        path = Path(temp)/'observer.sqlite'
        address = address_from_public_key(PrivateKey().public_key.format(compressed=False))
        Observer(path, None, address, now_ms=lambda: ms, start_ms=ms-1000)
        with closing(sqlite3.connect(path)) as c, c:
            c.execute('UPDATE observer_state SET checkpoint_ms=?', (ms,))
            c.execute('INSERT INTO observations VALUES (NULL,?,?,?,?,?,?,?,?)', (ms,ms,200,ms,'0',1,'SOURCE_MATCHED','0'))
            c.execute('INSERT INTO runs VALUES (NULL,?,?,?,NULL)', (ms,ms,'OK'))
        engine = create_engine('sqlite:///'+str(Path(temp)/'business.sqlite'))
        Base.metadata.create_all(engine)
        factory = create_session_factory(engine)
        with factory.begin() as s:
            s.add(WalletControl(id='global', withdrawals_paused=False))
        class Receipts:
            calls = []
            deferred = []
            fail = False
            def ingest(self, txid, *, actor_id, defer_credit=False):
                self.calls.append(txid)
                self.deferred.append(defer_credit)
                if self.fail: raise ValueError('sensitive-provider-details')
                return []
        receipts = Receipts()
        source = SQLiteFundingSource(path, official_address=address, clock=lambda: now[0])
        service = FundingScanService(factory, source=source, receipts=receipts,
            activation_baseline_time=now[0]-timedelta(seconds=1), activation_baseline_height=100, clock=lambda: now[0])
        yield service, source, receipts, factory, path, now, ms
        engine.dispose()


def add(scan, txid='a'*64, index=0, time=None, height=101, from_address='source', to_address='target'):
    _, _, _, _, path, _, ms = scan
    payload = dict(txid=txid, log_index=index, block_number=height, timestamp_ms=ms if time is None else time,
        from_address=from_address, to_address=to_address, amount_units=10000000)
    with closing(sqlite3.connect(path)) as c, c:
        c.execute('INSERT INTO events VALUES (?,?,?,?,?,?,?,?)',
            (txid,index,json.dumps(payload),payload['timestamp_ms'],'10000000','10000000','INFLOW','LIVE'))


def test_reserve_cut_preserves_exact_balance_and_changes_with_observation(scan):
    from dataclasses import FrozenInstanceError
    with closing(sqlite3.connect(scan[4])) as conn, conn:
        conn.execute("UPDATE observations SET balance_units='123456789012345678901234567890'")
    cut = scan[1].read_reserve_cut()
    assert cut.balance_units == 123456789012345678901234567890
    assert cut.observation_id == 1 and cut.max_rowid == 0 and cut.healthy
    assert cut.checkpoint_ms == scan[6] and cut.solid_block == 200
    assert cut.digest == scan[1].read_reserve_cut().digest
    with pytest.raises(FrozenInstanceError):
        cut.balance_units = 0
    add(scan)
    assert scan[1].read_reserve_cut().digest != cut.digest


def test_reserve_cut_retains_unhealthy_status_and_expiry(scan):
    first = scan[1].read_reserve_cut()
    scan[5][0] += timedelta(seconds=121)
    expired = scan[1].read_reserve_cut()
    assert expired.healthy is False
    assert expired.fresh_until_ms == first.fresh_until_ms
    assert expired.digest != first.digest


def test_discovery_exposes_exact_per_log_facts_for_coverage(scan):
    add(scan, index=3)
    event = scan[1].read_batch(after_rowid=0).events[0]
    assert event.log_index == 3
    assert event.amount_units == 10000000
    assert event.from_address == 'source' and event.to_address == 'target'


def test_activation_height_is_exclusive(scan):
    add(scan, height=100)
    assert scan[0].run_once(funds_enabled=True)['processed'] == 0
    assert scan[2].calls == []


def test_scan_defers_credit_and_requires_full_coverage_before_processed(scan):
    from app.modules.wallet.funding_scan import FundingScanService
    from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent
    # The scan fixture creates metadata before this optional integration import.
    WalletFundingCoverageEvent.__table__.create(scan[3].kw['bind'], checkfirst=True)
    class Coverage:
        source_identity = scan[1].source_identity
        status = 'PENDING'
        def verify_transaction(self, txid, *, actor_id):
            assert scan[2].deferred[-1] is True
            return {'status': self.status}
    coverage = Coverage()
    service = FundingScanService(scan[3], source=scan[1], receipts=scan[2], coverage=coverage, defer_credit=True,
        activation_baseline_time=scan[0].activation_baseline_time, activation_baseline_height=100, clock=scan[0].clock)
    add(scan, from_address=scan[1].official_address, to_address=scan[1].official_address)
    assert service.run_once(funds_enabled=False)['status'] == 'FUNDS_DISABLED'
    assert scan[2].calls == []
    with scan[3]() as session:
        assert len(session.scalars(select(WalletFundingCoverageEvent)).all()) == 1
    assert service.run_once(funds_enabled=True)['processed'] == 0
    assert service.status()['retry'] == 1
    coverage.status = 'VERIFIED'
    assert service.run_once(funds_enabled=True)['processed'] == 1
    assert service.status()['retry'] == 0


def test_restart_funds_off_and_multilog_dedup(scan):
    service, source, receipts, factory, *_ = scan
    add(scan); add(scan,index=1)
    result = service.run_once(funds_enabled=False)
    assert result['cursor_rowid'] == 2
    assert receipts.calls == []
    from app.modules.wallet.funding_scan import FundingScanService
    restarted = FundingScanService(factory, source=source, receipts=receipts,
        activation_baseline_time=service.activation_baseline_time, activation_baseline_height=100, clock=service.clock)
    assert restarted.run_once(funds_enabled=True)['processed'] == 1
    assert receipts.calls == ['a'*64]
    assert restarted.run_once(funds_enabled=True)['processed'] == 0


def test_late_older_log_requeues_processed_txid(scan):
    add(scan)
    scan[0].run_once(funds_enabled=True)
    add(scan,index=1,time=scan[6]-500)
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1
    assert len(scan[2].calls) == 2


def test_before_baseline_advances_without_queue(scan):
    add(scan,time=scan[6]-2000); add(scan,txid='b'*64,height=99)
    result = scan[0].run_once(funds_enabled=True)
    assert result['cursor_rowid'] == 2
    assert scan[2].calls == []


@pytest.mark.parametrize('fault', ['identity','malformed','regression','error','stale','unstable','unverified'])
def test_source_fault_blocks_credit(scan, fault):
    add(scan)
    scan[0].run_once(funds_enabled=False)
    with closing(sqlite3.connect(scan[4])) as c, c:
        if fault == 'identity': c.execute("UPDATE observer_state SET identity='fake'")
        elif fault == 'malformed':
            add(scan,txid='b'*64)
            c.execute("UPDATE events SET payload='{}' WHERE txid=?", ('b'*64,))
        elif fault == 'regression': c.execute('DELETE FROM events')
        elif fault == 'error': c.execute("UPDATE runs SET status='ERROR'")
        elif fault == 'unstable': c.execute('UPDATE observations SET stable_balance=0')
        elif fault == 'unverified': c.execute("UPDATE observations SET reconciliation='RECONCILIATION_UNVERIFIED'")
    if fault == 'stale': scan[5][0] += timedelta(seconds=121)
    result = scan[0].run_once(funds_enabled=True)
    assert result['processed'] == 0
    assert scan[2].calls == []
    assert 'sensitive' not in str(result)


def test_discovery_audit_rollback_is_atomic(scan, monkeypatch):
    from app.modules.wallet.funding_scan_models import WalletFundingScanState, WalletFundingScanItem
    from app.core.outbox import OutboxPublisher
    add(scan)
    def failure(*args, **kwargs): raise RuntimeError('sensitive-outbox-detail')
    monkeypatch.setattr(OutboxPublisher, 'enqueue', failure)
    result = scan[0].run_once(funds_enabled=True)
    assert result['processed'] == 0
    with scan[3]() as s:
        assert s.get(WalletFundingScanState,'global') is None
        assert s.scalar(select(WalletFundingScanItem)) is None


def test_retry_survives_failure(scan):
    add(scan); scan[2].fail=True
    assert scan[0].run_once(funds_enabled=True)['processed'] == 0
    scan[2].fail=False
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1


def test_readonly_missing_source_not_created(scan):
    from app.integrations.tron.funding_source import SQLiteFundingSource, FundingSourceError
    missing = scan[4].with_name('missing.sqlite')
    source = SQLiteFundingSource(missing, official_address=scan[1].official_address, clock=scan[0].clock)
    with pytest.raises(FundingSourceError): source.read_batch(after_rowid=0)
    assert not missing.exists()


def test_source_pagination_bounded(scan):
    for i in range(105): add(scan,txid=f'{i:064x}')
    batch = scan[1].read_batch(after_rowid=0)
    assert len(batch.events) == 100
    assert batch.next_rowid == 100 and batch.max_rowid == 105
    assert len(scan[1].read_batch(after_rowid=100).events) == 5


def test_malformed_noncredit_payload_is_rejected(scan):
    from app.integrations.tron.funding_source import FundingSourceError
    add(scan)
    with closing(sqlite3.connect(scan[4])) as c,c:
        payload = json.loads(c.execute('SELECT payload FROM events').fetchone()[0])
        payload['amount_units'] = 'NaN'
        c.execute('UPDATE events SET payload=?',(json.dumps(payload),))
    with pytest.raises(FundingSourceError): scan[1].read_batch(after_rowid=0)


def test_source_observation_age_checked_during_processing(scan):
    add(scan); add(scan,txid='b'*64)
    with closing(sqlite3.connect(scan[4])) as c,c:
        c.execute('UPDATE observations SET heartbeat_ms=?',(scan[6]-119000,))
    original = scan[2].ingest
    def slow(txid,*,actor_id):
        result = original(txid,actor_id=actor_id)
        scan[5][0] += timedelta(seconds=2)
        return result
    scan[2].ingest = slow
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1
    assert len(scan[2].calls) == 1


def test_crash_after_receipt_commit_retries_same_locator(scan,monkeypatch):
    add(scan)
    effects = set()
    original_ingest = scan[2].ingest
    def idempotent_ingest(txid,*,actor_id):
        effects.add(txid)
        return original_ingest(txid,actor_id=actor_id)
    scan[2].ingest = idempotent_ingest
    original_finish = scan[0]._finish
    def crash(*args): raise RuntimeError('simulated-process-loss')
    monkeypatch.setattr(scan[0],'_finish',crash)
    assert scan[0].run_once(funds_enabled=True)['status'] == 'INBOX_UPDATE_FAILED'
    monkeypatch.setattr(scan[0],'_finish',original_finish)
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1
    assert len(scan[2].calls) == 2 and len(effects) == 1


def test_new_discovery_during_ingest_not_lost(scan):
    add(scan)
    original = scan[2].ingest
    def ingest(txid,*,actor_id):
        result = original(txid,actor_id=actor_id)
        add(scan,index=1)
        scan[0].run_once(funds_enabled=False)
        return result
    scan[2].ingest = ingest
    scan[0].run_once(funds_enabled=True)
    assert scan[0].status()['pending'] == 1
    scan[2].ingest = original
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1


def test_processing_is_bounded(scan):
    for i in range(60): add(scan,txid=f'{i:064x}')
    assert scan[0].run_once(funds_enabled=True)['processed'] == 50
    assert scan[0].run_once(funds_enabled=True)['processed'] == 10


def test_checkpoint_regression_rejected(scan):
    add(scan); scan[0].run_once(funds_enabled=False)
    with closing(sqlite3.connect(scan[4])) as c,c:
        for table in ('observer_state','observations','runs'):
            c.execute(f'UPDATE {table} SET checkpoint_ms=?',(scan[6]-1,))
    assert scan[0].run_once(funds_enabled=True)['status'] == 'SOURCE_UNAVAILABLE'
    assert scan[2].calls == []


def test_concurrent_discovery_cannot_advance_stale_cursor(scan,monkeypatch):
    add(scan)
    original = scan[1].read_batch
    def competing(**kwargs):
        batch = original(**kwargs)
        monkeypatch.setattr(scan[1],'read_batch',original)
        scan[0].run_once(funds_enabled=False)
        return batch
    monkeypatch.setattr(scan[1],'read_batch',competing)
    assert scan[0].run_once(funds_enabled=True)['status'] == 'SOURCE_UNAVAILABLE'
    assert scan[0].status()['cursor_rowid'] == 1
    assert scan[2].calls == []
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1


def test_inconsistent_matched_health_rejected(scan):
    add(scan)
    with closing(sqlite3.connect(scan[4])) as c,c:
        c.execute("UPDATE observations SET difference_units='1'")
    assert scan[0].run_once(funds_enabled=True)['processed'] == 0
    assert scan[2].calls == []


def test_new_source_error_stops_remaining_inbox(scan):
    add(scan); add(scan,txid='b'*64)
    original = scan[2].ingest
    def ingest(txid,*,actor_id):
        result = original(txid,actor_id=actor_id)
        with closing(sqlite3.connect(scan[4])) as c,c:
            c.execute("UPDATE runs SET status='ERROR'")
        return result
    scan[2].ingest = ingest
    assert scan[0].run_once(funds_enabled=True)['processed'] == 1
    assert len(scan[2].calls) == 1
