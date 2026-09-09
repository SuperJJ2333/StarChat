"""Durable observation only: this module has no business/ledger dependencies."""

from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import time
from typing import Any, Callable, Protocol
from . import diagnostics as diag


class SnapshotReader(Protocol):
    def snapshot(self, address: str, start_ms: int, end_ms: int) -> dict: ...


class ObservationError(Exception):
    """Only constant local reason codes may leave the observer."""


def _integer(value: Any) -> int:
    if type(value) is not int or value < 0:
        raise ObservationError("INVALID_SNAPSHOT")
    return value


class Observer:
    """One bounded, atomic historical window per call; retry never loses its watermark.

    The database must be in a restricted runtime directory, never a business DB.
    Amounts are decimal integer strings in SQLite to retain TRC20 uint256 precision.
    A snapshot reader must finish all pages before returning and raise on partial data.
    The checkpoint is a source traversal watermark, not proof of chain completeness.
    SOURCE_MATCHED compares one source only and never authorizes financial writes.
    """

    def __init__(self, path: str | Path, reader: SnapshotReader, address: str,
                 now_ms: Callable[[], int] | None = None, start_ms: int | None = None,
                 overlap_ms: int = 120_000, batch_ms: int = 86_400_000):
        self.path = Path(path)
        self.reader = reader
        self.address = address
        self.now_ms = now_ms or (lambda: time.time_ns() // 1_000_000)
        self.overlap_ms = _integer(overlap_ms)
        self.batch_ms = _integer(batch_ms)
        if not self.batch_ms or not address or str(path) == ":memory:":
            raise ValueError("INVALID_OBSERVER_CONFIGURATION")
        now = _integer(self.now_ms())
        start = now if start_ms is None else _integer(start_ms)
        if start > now:
            raise ValueError("INVALID_OBSERVER_CONFIGURATION")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive creation with restrictive POSIX mode; deployment also restricts directory ACLs.
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(fd)
        with closing(self._connect()) as conn, conn:
            tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            expected = {"observer_state", "events", "observations", "runs"}
            if tables and tables != expected:
                raise ValueError("OBSERVER_DATABASE_REQUIRED")
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS observer_state (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1), identity TEXT NOT NULL,
                    start_ms INTEGER NOT NULL, live_started_ms INTEGER NOT NULL,
                    checkpoint_ms INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS events (
                    txid TEXT NOT NULL, log_index INTEGER NOT NULL, payload TEXT NOT NULL,
                    timestamp_ms INTEGER NOT NULL, amount_units TEXT NOT NULL,
                    net_units TEXT NOT NULL, classification TEXT NOT NULL, era TEXT NOT NULL,
                    PRIMARY KEY(txid, log_index));
                CREATE TABLE IF NOT EXISTS observations (
                    id INTEGER PRIMARY KEY, heartbeat_ms INTEGER NOT NULL,
                    checkpoint_ms INTEGER NOT NULL, solid_block INTEGER NOT NULL,
                    solid_timestamp_ms INTEGER NOT NULL, balance_units TEXT NOT NULL,
                    stable_balance INTEGER NOT NULL, reconciliation TEXT NOT NULL,
                    difference_units TEXT);
                CREATE TABLE IF NOT EXISTS runs (
                    id INTEGER PRIMARY KEY, heartbeat_ms INTEGER NOT NULL,
                    checkpoint_ms INTEGER NOT NULL, status TEXT NOT NULL, error_code TEXT);
            """)
            identity = hashlib.sha256(("tron-mainnet-usdt:" + address).encode()).hexdigest()
            conn.execute("INSERT OR IGNORE INTO observer_state VALUES (1,?,?,?,?)", (identity, start, now, start))
            if conn.execute("SELECT identity FROM observer_state").fetchone()[0] != identity:
                raise ValueError("OBSERVER_IDENTITY_MISMATCH")

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn

    @diag.traced('observer')
    def run_once(self) -> dict:
        started = time.monotonic()
        now = _integer(self.now_ms())
        with closing(self._connect()) as conn:
            # Serialize competing observers so a slower request cannot regress the watermark.
            conn.execute("BEGIN IMMEDIATE")
            state = conn.execute("SELECT * FROM observer_state").fetchone()
            checkpoint = state["checkpoint_ms"]
            start = max(state["start_ms"], checkpoint - self.overlap_ms)
            end = min(now, checkpoint + self.batch_ms)
            added = outflows = 0
            live_outflows = historical_outflows = 0
            reconciliation = "RECONCILIATION_UNVERIFIED"
            error_code = None
            balance = None
            block = None
            try:
                if end < checkpoint:
                    raise ObservationError("CLOCK_REGRESSION")
                data = self.reader.snapshot(self.address, start, end)
                balance = _integer(data["balance_units"])
                block = _integer(data["solid_block"])
                solid_time = _integer(data["solid_timestamp_ms"])
                stable = data["stable_balance"]
                if type(stable) is not bool or not isinstance(data["events"], list):
                    raise ObservationError("INVALID_SNAPSHOT")
                complete_end = min(end, solid_time)
                if complete_end < checkpoint:
                    raise ObservationError("SOLID_HEAD_BEHIND_CHECKPOINT")
                for raw in data["events"]:
                    event = {key: raw[key] for key in (
                        "txid", "log_index", "block_number", "timestamp_ms",
                        "from_address", "to_address", "amount_units")}
                    for key in ("log_index", "block_number", "timestamp_ms", "amount_units"):
                        _integer(event[key])
                    for key in ("txid", "from_address", "to_address"):
                        if not isinstance(event[key], str) or not event[key]:
                            raise ObservationError("INVALID_SNAPSHOT")
                    if (event["block_number"] > block
                            or not start <= event["timestamp_ms"] <= complete_end):
                        raise ObservationError("INVALID_SNAPSHOT")
                    incoming = event["to_address"] == self.address
                    outgoing = event["from_address"] == self.address
                    if not incoming and not outgoing:
                        raise ObservationError("INVALID_SNAPSHOT")
                    payload = json.dumps(event, sort_keys=True, separators=(",", ":"))
                    previous = conn.execute("SELECT payload FROM events WHERE txid=? AND log_index=?",
                                            (event["txid"], event["log_index"])).fetchone()
                    if previous:
                        if previous[0] != payload:
                            raise ObservationError("EVENT_CONFLICT")
                        continue
                    net = event["amount_units"] * (int(incoming) - int(outgoing))
                    classification = "UNMATCHED_OUTFLOW" if outgoing else "INFLOW"
                    era = "HISTORICAL" if event["timestamp_ms"] < state["live_started_ms"] else "LIVE"
                    conn.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)",
                                 (event["txid"], event["log_index"], payload, event["timestamp_ms"],
                                  str(event["amount_units"]), str(net), classification, era))
                    added += 1
                    outflows += int(outgoing)
                    live_outflows += int(outgoing and era == "LIVE")
                    historical_outflows += int(outgoing and era == "HISTORICAL")
                previous = conn.execute("SELECT * FROM observations ORDER BY id DESC LIMIT 1").fetchone()
                difference = None
                if (previous and stable and previous["stable_balance"]
                        and previous["solid_timestamp_ms"] == checkpoint
                        and solid_time == complete_end and start <= checkpoint
                        and block >= previous["solid_block"] and solid_time >= checkpoint):
                    net = sum(int(row[0]) for row in conn.execute(
                        "SELECT net_units, payload FROM events WHERE timestamp_ms>=? AND timestamp_ms<=?",
                        (checkpoint, solid_time))
                        if previous["solid_block"] < json.loads(row[1])["block_number"] <= block)
                    difference = balance - int(previous["balance_units"]) - net
                    reconciliation = "SOURCE_MATCHED" if difference == 0 else "BALANCE_DISCREPANCY"
                checkpoint = complete_end
                observation_cursor = conn.execute("INSERT INTO observations VALUES (NULL,?,?,?,?,?,?,?,?)",
                             (now, checkpoint, block, solid_time, str(balance), int(stable),
                              reconciliation, None if difference is None else str(difference)))
                conn.execute("UPDATE observer_state SET checkpoint_ms=?", (checkpoint,))
                run_cursor = conn.execute("INSERT INTO runs VALUES (NULL,?,?,?,NULL)", (now, checkpoint, "OK"))
                conn.commit()
                diag.emit('INFO', 'scan_completed', component='observer', run_id=run_cursor.lastrowid,
                          observation_id=observation_cursor.lastrowid, checkpoint_ms=checkpoint, solid_block=block,
                          solid_timestamp_ms=solid_time, reconciliation=reconciliation,
                          events_added=added, duration_ms=int((time.monotonic()-started)*1000))
                diag.state('INFO' if reconciliation == 'SOURCE_MATCHED' else 'WARNING',
                           'scan_state', component='observer', reason_code=reconciliation)
            except Exception as exc:
                conn.rollback()
                checkpoint = state["checkpoint_ms"]
                added = outflows = 0
                live_outflows = historical_outflows = 0
                balance = None
                block = None
                reconciliation = "RECONCILIATION_UNVERIFIED"
                error_code = str(exc) if isinstance(exc, ObservationError) else "SNAPSHOT_FAILED"
                with conn:
                    failed_cursor = conn.execute("INSERT INTO runs VALUES (NULL,?,?,?,?)", (now, checkpoint, "ERROR", error_code))
                diag.emit('ERROR', 'scan_failed', component='observer',
                          reason_code=diag.validation_reason(exc), checkpoint_ms=checkpoint,
                          run_id=failed_cursor.lastrowid,
                          duration_ms=int((time.monotonic()-started)*1000), **diag.exception_info(exc))
                diag.state('WARNING', 'scan_state', component='observer', reason_code='SCAN_FAILED')
            return dict(status="ERROR" if error_code else "OK", checkpoint_ms=checkpoint,
                        coverage_start_ms=state["start_ms"], live_started_ms=state["live_started_ms"],
                        heartbeat_ms=now, lag_ms=max(0, now - checkpoint), events_added=added,
                        outflows_added=outflows, reconciliation=reconciliation, error_code=error_code,
                        live_outflows_added=live_outflows, historical_outflows_added=historical_outflows,
                        balance_units=None if balance is None else str(balance), solid_block=block)
