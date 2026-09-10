"""Atomic read-only reserve classifications and bounded SQLite reads."""

from contextlib import closing
from dataclasses import FrozenInstanceError, asdict
from datetime import timedelta
import hashlib
import json
import sqlite3
import time

import pytest

from app.integrations.tron import funding_source
from test_funding_scan import scan as scan


def test_age_only_sample_keeps_original_cut_and_digest(scan):
    source = scan[1]
    original = source.read_reserve_cut()
    assert hasattr(source, "read_reserve_sample")
    assert source.read_reserve_sample().cut == original
    assert source.read_reserve_sample().age_expired_only is False
    scan[5][0] += timedelta(seconds=121)
    sample = source.read_reserve_sample()
    assert sample.age_expired_only is True and sample.cut.healthy is False
    assert sample.cut == source.read_reserve_cut()
    values = asdict(sample.cut)
    digest = values.pop("digest")
    assert (
        digest
        == hashlib.sha256(
            json.dumps(values, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
    )
    assert set(values) == {
        "source_identity",
        "observation_id",
        "max_rowid",
        "checkpoint_ms",
        "solid_block",
        "balance_units",
        "heartbeat_ms",
        "fresh_until_ms",
        "healthy",
    }
    with pytest.raises(FrozenInstanceError):
        sample.age_expired_only = False


@pytest.mark.parametrize(
    "update",
    [
        "UPDATE runs SET status='ERROR'",
        "UPDATE runs SET error_code='SNAPSHOT_FAILED'",
        "UPDATE observations SET stable_balance=0",
        "UPDATE observations SET reconciliation='BALANCE_DISCREPANCY', difference_units='1'",
        "UPDATE observations SET reconciliation='RECONCILIATION_UNVERIFIED'",
        "UPDATE runs SET heartbeat_ms=heartbeat_ms+200000",
        "UPDATE observations SET heartbeat_ms=heartbeat_ms+200000",
        "UPDATE observations SET solid_timestamp_ms=solid_timestamp_ms+200000",
    ],
)
def test_stale_with_other_fault_is_never_age_only(scan, update):
    scan[5][0] += timedelta(seconds=121)
    with closing(sqlite3.connect(scan[4])) as conn, conn:
        conn.execute(update)
    assert hasattr(scan[1], "read_reserve_sample")
    assert scan[1].read_reserve_sample().age_expired_only is False


def test_fresh_pending_preserves_exception(scan):
    with closing(sqlite3.connect(scan[4])) as conn, conn:
        conn.execute(
            "UPDATE observations SET reconciliation='RECONCILIATION_UNVERIFIED'"
        )
    assert hasattr(scan[1], "read_reserve_sample")
    with pytest.raises(funding_source.FundingSourcePending):
        scan[1].read_reserve_sample()


@pytest.mark.parametrize(
    "budget", [0, -1, 5.01, float("inf"), float("nan"), True, "1", None]
)
def test_invalid_read_budget_is_rejected(scan, budget):
    with pytest.raises(funding_source.FundingSourceError, match="SOURCE_READ_BUDGET"):
        scan[1].read_batch(after_rowid=0, timeout_seconds=budget)


def test_read_budget_covers_sql_execution_and_remains_readonly(scan, monkeypatch):
    original = sqlite3.connect
    observed = []

    class SlowConnection(sqlite3.Connection):
        def execute(self, sql, parameters=()):
            if sql.startswith("SELECT * FROM observer_state"):
                super().execute(
                    "WITH RECURSIVE slow(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM slow WHERE n<100000000) SELECT sum(n) FROM slow"
                ).fetchone()
            return super().execute(sql, parameters)

    def connect(database, **kwargs):
        observed.append((database, kwargs["timeout"]))
        return original(database, **kwargs, factory=SlowConnection)

    monkeypatch.setattr(funding_source.sqlite3, "connect", connect)
    started = time.monotonic()
    with pytest.raises(funding_source.FundingSourceError) as failure:
        scan[1].read_batch(after_rowid=0, timeout_seconds=0.03)
    assert str(failure.value) == "SOURCE_READ_BUDGET_EXPIRED", repr(
        failure.value.__context__
    )
    assert time.monotonic() - started < 0.5
    assert observed[0][0].endswith("?mode=ro")
    assert 0 < observed[0][1] <= 0.03


def test_missing_budgeted_source_is_not_created(scan):
    source = funding_source.SQLiteFundingSource(
        scan[4].with_name("missing.sqlite"),
        official_address=scan[1].official_address,
        clock=scan[1].clock,
    )
    assert hasattr(source, "read_reserve_sample")
    with pytest.raises(funding_source.FundingSourceError):
        source.read_reserve_sample(timeout_seconds=0.1)
    assert not source.path.exists()


def test_classification_and_cut_share_transaction_during_writer_update(
    scan, monkeypatch
):
    scan[5][0] += timedelta(seconds=121)
    with closing(sqlite3.connect(scan[4])) as conn:
        conn.execute("PRAGMA journal_mode=WAL")

    def update_observer(**kwargs):
        with closing(sqlite3.connect(scan[4])) as conn, conn:
            conn.execute(
                "UPDATE observations SET balance_units='999', stable_balance=0"
            )

    monkeypatch.setattr(funding_source.diag, "source_health", update_observer)
    sample = scan[1].read_reserve_sample()
    assert sample.age_expired_only is True and sample.cut.balance_units == 0
    assert scan[1].read_reserve_sample().age_expired_only is False


def test_sqlite_exclusive_lock_wait_is_bounded(scan):
    with closing(sqlite3.connect(scan[4])) as conn:
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.execute("BEGIN EXCLUSIVE")
        started = time.monotonic()
        with pytest.raises(funding_source.FundingSourceError):
            scan[1].read_reserve_sample(timeout_seconds=0.03)
        assert time.monotonic() - started < 0.5
        conn.rollback()
