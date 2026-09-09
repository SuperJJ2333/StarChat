from contextlib import closing
from datetime import timedelta
import sqlite3

import pytest
from test_funding_scan import scan  # noqa: F401
from test_tron_finality import NOW, MS, block


def test_fresh_observation_can_contain_older_solid_head(scan):
    from app.integrations.tron.funding_source import SQLiteFundingSource
    _, existing, _, _, path, clock, original_ms = scan
    clock[0] += timedelta(seconds=145)
    now_ms = int(clock[0].timestamp()*1000)
    with closing(sqlite3.connect(path)) as c, c:
        c.execute('UPDATE runs SET heartbeat_ms=?', (now_ms-10000,))
        c.execute('UPDATE observations SET heartbeat_ms=?', (now_ms-10000,))
    source = SQLiteFundingSource(path, official_address=existing.official_address,
        clock=lambda:clock[0], max_age_seconds=120, solid_head_max_age_seconds=180)
    batch = source.read_batch(after_rowid=0)
    assert batch.healthy
    assert batch.fresh_until_ms == original_ms+180000
    clock[0] += timedelta(seconds=36)
    assert not source.read_batch(after_rowid=0).healthy


def test_old_acquisition_is_not_extended_by_head_limit(scan):
    from app.integrations.tron.funding_source import SQLiteFundingSource
    clock = scan[5]
    source = SQLiteFundingSource(scan[4], official_address=scan[1].official_address,
        clock=lambda:clock[0], max_age_seconds=120, solid_head_max_age_seconds=180)
    clock[0] += timedelta(seconds=121)
    assert not source.read_batch(after_rowid=0).healthy


def test_finality_separates_observation_and_solid_head_expiry():
    import httpx
    from app.integrations.tron.finality import TronGridFinality, TronEvidenceUnavailable
    clock = [NOW]
    adapter = TronGridFinality(base_url='https://api.trongrid.io', clock=lambda:clock[0],
        max_age_seconds=120, solid_head_max_age_seconds=180,
        transport=httpx.MockTransport(lambda r:httpx.Response(200,json=block(timestamp=MS-145000))))
    head = adapter.solid_head()
    assert head.observed_at == NOW
    clock[0] += timedelta(seconds=36)
    with pytest.raises(TronEvidenceUnavailable):
        adapter.solid_head()
    adapter.close()


def test_unstable_sampling_is_pending_without_fabricating_a_reserve_cut(scan):
    from app.integrations.tron.funding_source import FundingSourcePending
    with closing(sqlite3.connect(scan[4])) as c, c:
        c.execute("UPDATE observations SET stable_balance=0, reconciliation='RECONCILIATION_UNVERIFIED', difference_units=NULL")
    assert not scan[1].read_batch(after_rowid=0).healthy
    with pytest.raises(FundingSourcePending) as caught:
        scan[1].read_reserve_cut()
    assert caught.value.since_ms == scan[6]
    with closing(sqlite3.connect(scan[4])) as c, c:
        c.execute("UPDATE observations SET stable_balance=1, reconciliation='BALANCE_DISCREPANCY', difference_units='1'")
    assert not scan[1].read_reserve_cut().healthy


def test_pending_duration_survives_observations_and_source_restart(scan):
    from app.integrations.tron.funding_source import SQLiteFundingSource, FundingSourcePending
    _, source, _, _, path, clock, ms = scan
    for offset in (30000, 60000):
        clock[0] += timedelta(seconds=30)
        with closing(sqlite3.connect(path)) as c, c:
            c.execute('UPDATE runs SET heartbeat_ms=?', (ms+offset,))
            c.execute('INSERT INTO observations VALUES (NULL,?,?,?,?,?,?,?,?)',
                (ms+offset, ms, 201, ms+offset, '0', 0, 'RECONCILIATION_UNVERIFIED', None))
        restarted = SQLiteFundingSource(path, official_address=source.official_address, clock=lambda:clock[0])
        with pytest.raises(FundingSourcePending) as caught:
            restarted.read_reserve_cut()
        assert caught.value.since_ms == ms+30000


def test_unclassified_snapshot_failure_waits_without_accepting_old_balance(scan):
    from app.integrations.tron.funding_source import FundingSourcePending
    _, source, _, _, path, clock, ms = scan
    clock[0] += timedelta(seconds=30)
    with closing(sqlite3.connect(path)) as c, c:
        c.execute('INSERT INTO runs VALUES (NULL,?,?,?,?)',(ms+30000,ms,'ERROR','SNAPSHOT_FAILED'))
    with pytest.raises(FundingSourcePending) as caught:
        source.read_reserve_cut()
    assert caught.value.since_ms == ms+30000
    assert not source.read_batch(after_rowid=0).healthy
    clock[0] += timedelta(seconds=91)
    assert not source.read_reserve_cut().healthy
