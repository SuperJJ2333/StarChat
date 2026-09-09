import importlib
import sqlite3

import pytest


ADDRESS = "synthetic-observed-address"


def observer_type():
    try:
        module = importlib.import_module("app.integrations.tron.observer")
    except ModuleNotFoundError:
        pytest.fail("durable read-only Observer is not implemented")
    return module.Observer


class Reader:
    def __init__(self, *results):
        self.results = iter(results)
        self.calls = []

    def snapshot(self, address, start_ms, end_ms):
        self.calls.append((address, start_ms, end_ms))
        result = next(self.results)
        if isinstance(result, Exception):
            raise result
        return result


def snapshot(events=(), balance=0, timestamp=1000, stable=False):
    return dict(events=list(events), balance_units=balance, solid_block=timestamp,
                solid_timestamp_ms=timestamp, stable_balance=stable)


def event(txid="a", amount=10, timestamp=950):
    return dict(txid=txid, log_index=0, block_number=timestamp,
                timestamp_ms=timestamp, from_address=ADDRESS,
                to_address="synthetic-recipient", amount_units=amount)


def rows(path, table):
    with sqlite3.connect(path) as conn:
        conn.row_factory = sqlite3.Row
        return [dict(row) for row in conn.execute(f"SELECT * FROM {table}")]


def test_restart_overlap_idempotency_and_original_live_boundary(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot([event()]), snapshot([event(), event("b", timestamp=1500)], timestamp=2000))
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: 1000, start_ms=0, overlap_ms=100)
    initial = observer.run_once()
    assert initial["events_added"] == 1
    assert initial["historical_outflows_added"] == 1
    assert initial["live_outflows_added"] == 0
    restarted = observer_type()(path, reader, ADDRESS, now_ms=lambda: 2000, start_ms=1999, overlap_ms=100)
    result = restarted.run_once()
    assert result["events_added"] == 1
    assert result["live_outflows_added"] == 1
    assert result["historical_outflows_added"] == 0
    assert reader.calls[-1] == (ADDRESS, 900, 2000)
    assert [r["era"] for r in rows(path, "events")] == ["HISTORICAL", "LIVE"]
    assert all(r["classification"] == "UNMATCHED_OUTFLOW" for r in rows(path, "events"))
    assert ADDRESS not in str(result)


def test_failed_page_keeps_checkpoint_and_persists_safe_failure(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot(), RuntimeError("page failed " + ADDRESS), snapshot(timestamp=2000))
    now = [1000]
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: now[0], start_ms=0)
    observer.run_once()
    now[0] = 2000
    result = observer.run_once()
    assert result["status"] == "ERROR"
    assert result["checkpoint_ms"] == 1000
    assert rows(path, "runs")[-1]["heartbeat_ms"] == 2000
    assert ADDRESS not in str(result) + str(rows(path, "runs"))
    assert observer.run_once()["checkpoint_ms"] == 2000


def test_conflicting_duplicate_rolls_back_whole_window(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot([event()]), snapshot([event("new"), event(amount=11)], timestamp=2000))
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: 2000, start_ms=0)
    observer.run_once()
    result = observer.run_once()
    assert result["error_code"] == "EVENT_CONFLICT"
    assert len(rows(path, "events")) == 1
    assert rows(path, "events")[0]["amount_units"] == "10"


@pytest.mark.parametrize("balance", [None, -1, True, 0.5])
def test_missing_invalid_balance_never_becomes_zero(tmp_path, balance):
    path = tmp_path / "observer.db"
    observer = observer_type()(path, Reader(snapshot(balance=balance)), ADDRESS, now_ms=lambda: 1000, start_ms=0)
    assert observer.run_once()["status"] == "ERROR"
    assert not rows(path, "observations")


def test_zero_valid_but_initial_and_unstable_balances_unverified(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot(stable=True), snapshot(timestamp=2000, stable=False))
    now = [1000]
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: now[0], start_ms=0)
    assert observer.run_once()["reconciliation"] == "RECONCILIATION_UNVERIFIED"
    now[0] = 2000
    assert observer.run_once()["reconciliation"] == "RECONCILIATION_UNVERIFIED"
    assert len(rows(path, "observations")) == 2


def test_reconcile_only_aligned_stable_boundaries_and_persist_discrepancy(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot(balance=100, stable=True),
                    snapshot([event(timestamp=1500)], balance=90, timestamp=2000, stable=True),
                    snapshot(balance=89, timestamp=3000, stable=True))
    now = [1000]
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: now[0], start_ms=0, overlap_ms=100)
    observer.run_once()
    now[0] = 2000
    assert observer.run_once()["reconciliation"] == "SOURCE_MATCHED"
    now[0] = 3000
    assert observer.run_once()["reconciliation"] == "BALANCE_DISCREPANCY"
    assert rows(path, "observations")[-1]["difference_units"] == "-1"


def test_stable_balance_after_queried_window_is_not_reconciled(tmp_path):
    path = tmp_path / "observer.db"
    reader = Reader(snapshot(timestamp=5000, stable=True), snapshot(timestamp=6000, stable=True))
    observer = observer_type()(path, reader, ADDRESS, now_ms=lambda: 10000, start_ms=0, batch_ms=1000)
    assert observer.run_once()["checkpoint_ms"] == 1000
    result = observer.run_once()
    assert result["checkpoint_ms"] == 2000
    assert result["reconciliation"] == "RECONCILIATION_UNVERIFIED"


def test_rejects_existing_financial_database_without_mutation(tmp_path):
    path = tmp_path / "business.db"
    with sqlite3.connect(path) as conn:
        conn.execute("CREATE TABLE ledger_entries(amount TEXT)")
        conn.execute("INSERT INTO ledger_entries VALUES ('123.00')")
    original = path.read_bytes()
    with pytest.raises(ValueError, match="OBSERVER_DATABASE_REQUIRED"):
        observer_type()(path, Reader(), ADDRESS, now_ms=lambda: 1000)
    assert path.read_bytes() == original


def test_database_identity_cannot_switch_address(tmp_path):
    path = tmp_path / "observer.db"
    observer_type()(path, Reader(), ADDRESS, now_ms=lambda: 1000)
    with pytest.raises(ValueError, match="OBSERVER_IDENTITY_MISMATCH"):
        observer_type()(path, Reader(), "different-address", now_ms=lambda: 1000)


def test_events_outside_requested_window_are_rejected(tmp_path):
    path = tmp_path / "observer.db"
    observer = observer_type()(path, Reader(snapshot([event(timestamp=100)])), ADDRESS,
                               now_ms=lambda: 1000, start_ms=500)
    assert observer.run_once()["status"] == "ERROR"
    assert not rows(path, "events")


def test_huge_integer_precision_and_safe_coverage_summary(tmp_path):
    path = tmp_path / "observer.db"
    amount = 2**255
    observer = observer_type()(path, Reader(snapshot([event(amount=amount)], balance=amount)),
                               ADDRESS, now_ms=lambda: 1000, start_ms=50)
    result = observer.run_once()
    assert result["coverage_start_ms"] == 50
    assert result["solid_block"] == 1000
    assert result["balance_units"] == str(amount)
    assert rows(path, "events")[0]["amount_units"] == str(amount)


def test_boundary_block_flow_is_counted_even_at_same_timestamp(tmp_path):
    path = tmp_path / "observer.db"
    first = snapshot(balance=100, timestamp=1000, stable=True)
    second_event = event(timestamp=1000)
    second_event["block_number"] = 1001
    second = snapshot([second_event], balance=90, timestamp=2000, stable=True)
    now = [1000]
    observer = observer_type()(path, Reader(first, second), ADDRESS, now_ms=lambda: now[0], start_ms=0)
    observer.run_once()
    now[0] = 2000
    assert observer.run_once()["reconciliation"] == "SOURCE_MATCHED"
