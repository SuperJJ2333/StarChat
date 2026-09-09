"""Read-only discovery, never finality proof.

Observer events must remain append-only: no DELETE, rowid rewrite or VACUUM.
Restore regressions are rejected by the durable consumer; restoring a different
history with identical watermarks requires operator-controlled revalidation.
"""
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from . import diagnostics as diag

from app.integrations.tron.message_signature import canonical_address


class FundingSourceError(ValueError):
    """Constant local reason only, no provider or filesystem details."""


class FundingSourcePending(FundingSourceError):
    """Fresh but not yet reconciled sampling; no balance evidence is supplied."""
    def __init__(self, since_ms, fresh_until_ms):
        super().__init__('SOURCE_SAMPLING_PENDING')
        self.since_ms, self.fresh_until_ms = since_ms, fresh_until_ms


@dataclass(frozen=True)
class SourceEvent:
    rowid: int
    txid: str
    timestamp_ms: int
    block_number: int
    log_index: int
    amount_units: int
    from_address: str
    to_address: str


@dataclass(frozen=True)
class SourceBatch:
    source_identity: str
    after_rowid: int
    next_rowid: int
    max_rowid: int
    checkpoint_ms: int
    heartbeat_ms: int
    solid_block: int
    stable_balance: bool
    reconciliation: str
    healthy: bool
    fresh_until_ms: int
    events: tuple[SourceEvent, ...]
    observation_id: int = 0
    balance_units: int | None = None
    pending_since_ms: int | None = None


@dataclass(frozen=True)
class ReserveCut:
    source_identity: str
    observation_id: int
    max_rowid: int
    checkpoint_ms: int
    solid_block: int
    balance_units: int
    heartbeat_ms: int
    fresh_until_ms: int
    healthy: bool
    digest: str


def _integer(value):
    if type(value) is not int or not 0 <= value < 2**63:
        raise FundingSourceError('SOURCE_MALFORMED')
    return value


class SQLiteFundingSource:
    def __init__(self, path, *, official_address, clock, max_age_seconds=120, solid_head_max_age_seconds=None):
        canonical_address(official_address)
        if not callable(clock) or type(max_age_seconds) is not int or not 1 <= max_age_seconds <= 120:
            raise ValueError('bounded source freshness and clock required')
        self.path, self.official_address, self.clock = Path(path), official_address, clock
        self.source_identity = hashlib.sha256(('tron-mainnet-usdt:'+official_address).encode()).hexdigest()
        self.max_age_seconds = max_age_seconds
        head_limit = max_age_seconds if solid_head_max_age_seconds is None else solid_head_max_age_seconds
        if type(head_limit) is not int or not 1 <= head_limit <= 300:
            raise ValueError('bounded solid head age required')
        self.solid_head_max_age_seconds = head_limit

    def read_reserve_cut(self):
        """One observer transaction; this is discovery coverage, not finality proof."""
        batch = self.read_batch(after_rowid=0, limit=1)
        if batch.pending_since_ms is not None:
            raise FundingSourcePending(batch.pending_since_ms, batch.fresh_until_ms)
        values = {key: getattr(batch, key) for key in ('source_identity', 'observation_id',
            'max_rowid', 'checkpoint_ms', 'solid_block', 'balance_units', 'heartbeat_ms',
            'fresh_until_ms', 'healthy')}
        digest = hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        return ReserveCut(**values, digest=digest)

    def read_batch(self, *, after_rowid, limit=100):
        _integer(after_rowid)
        if type(limit) is not int or not 1 <= limit <= 100:
            raise FundingSourceError('SOURCE_BATCH_LIMIT')
        now = self.clock()
        if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise ValueError('aware server clock required')
        now_ms = int(now.astimezone(timezone.utc).timestamp()*1000)
        try:
            with closing(sqlite3.connect(self.path.resolve().as_uri()+'?mode=ro', uri=True, timeout=5)) as conn:
                conn.row_factory = sqlite3.Row
                conn.execute('BEGIN')
                state = conn.execute('SELECT * FROM observer_state WHERE singleton=1').fetchone()
                if state is None or state['identity'] != self.source_identity:
                    raise FundingSourceError('SOURCE_IDENTITY_MISMATCH')
                checkpoint = _integer(state['checkpoint_ms'])
                if checkpoint < _integer(state['start_ms']):
                    raise FundingSourceError('SOURCE_REGRESSION')
                maximum = _integer(conn.execute('SELECT COALESCE(MAX(rowid),0) FROM events').fetchone()[0])
                if maximum < after_rowid:
                    raise FundingSourceError('SOURCE_REGRESSION')
                run = conn.execute('SELECT * FROM runs ORDER BY id DESC LIMIT 1').fetchone()
                observation = conn.execute('SELECT * FROM observations ORDER BY id DESC LIMIT 1').fetchone()
                if run is None or observation is None:
                    raise FundingSourceError('SOURCE_HEALTH_MISSING')
                heartbeat = _integer(run['heartbeat_ms'])
                observed = _integer(observation['heartbeat_ms'])
                solid = _integer(observation['solid_block'])
                solid_ms = _integer(observation['solid_timestamp_ms'])
                if (_integer(run['checkpoint_ms']) != checkpoint or _integer(observation['checkpoint_ms']) != checkpoint
                        or solid_ms < checkpoint or run['status'] not in ('OK','ERROR')
                        or observation['stable_balance'] not in (0,1)):
                    raise FundingSourceError('SOURCE_MALFORMED')
                reconciliation = observation['reconciliation']
                if reconciliation not in ('SOURCE_MATCHED','BALANCE_DISCREPANCY','RECONCILIATION_UNVERIFIED'):
                    raise FundingSourceError('SOURCE_MALFORMED')
                balance = observation['balance_units']
                difference = observation['difference_units']
                if (not isinstance(balance,str) or re.fullmatch('[0-9]{1,78}',balance) is None
                        or difference is not None and (not isinstance(difference,str) or re.fullmatch('-?[0-9]+',difference) is None)
                        or reconciliation == 'SOURCE_MATCHED' and difference != '0'):
                    raise FundingSourceError('SOURCE_MALFORMED')
                stable = bool(observation['stable_balance'])
                fresh = (all(0 <= now_ms-value <= self.max_age_seconds*1000 for value in (heartbeat,observed))
                    and 0 <= now_ms-solid_ms <= self.solid_head_max_age_seconds*1000)
                healthy = fresh and run['status'] == 'OK' and run['error_code'] is None and stable and reconciliation == 'SOURCE_MATCHED'
                diag.source_health(now_ms=now_ms, heartbeat=heartbeat, observed=observed,
                    solid_ms=solid_ms, max_age_seconds=self.max_age_seconds,
                    head_limit=self.solid_head_max_age_seconds, observation_id=observation['id'],
                    status=run['status'], stable=stable, reconciliation=reconciliation, healthy=healthy,
                    run_id=run['id'], fresh_until_ms=min(min(heartbeat,observed)+self.max_age_seconds*1000,
                                                      solid_ms+self.solid_head_max_age_seconds*1000))
                pending_since = None
                if fresh and run['status'] == 'OK' and run['error_code'] is None and reconciliation == 'RECONCILIATION_UNVERIFIED':
                    pending_since = _integer(conn.execute("""SELECT MIN(heartbeat_ms) FROM observations
                        WHERE id > COALESCE((SELECT MAX(id) FROM observations
                            WHERE stable_balance=1 AND reconciliation='SOURCE_MATCHED'),0)""").fetchone()[0])
                    if pending_since > observed:
                        raise FundingSourceError('SOURCE_MALFORMED')
                if (fresh and run['status'] == 'ERROR' and run['error_code'] == 'SNAPSHOT_FAILED'
                        and reconciliation != 'BALANCE_DISCREPANCY'):
                    failed_since = _integer(conn.execute("""SELECT MIN(heartbeat_ms) FROM runs
                        WHERE id > COALESCE((SELECT MAX(id) FROM runs WHERE status='OK' AND error_code IS NULL),0)
                        """).fetchone()[0])
                    if failed_since > heartbeat:
                        raise FundingSourceError('SOURCE_MALFORMED')
                    pending_since = failed_since
                    if reconciliation == 'RECONCILIATION_UNVERIFIED':
                        pending_since = min(pending_since, _integer(conn.execute("""SELECT MIN(heartbeat_ms)
                            FROM observations WHERE id > COALESCE((SELECT MAX(id) FROM observations
                            WHERE stable_balance=1 AND reconciliation='SOURCE_MATCHED'),0)""").fetchone()[0]))
                events = []
                rows = conn.execute('SELECT rowid,txid,log_index,payload,timestamp_ms FROM events WHERE rowid>? ORDER BY rowid LIMIT ?', (after_rowid,limit))
                for row in rows:
                    payload = json.loads(row['payload'])
                    if not isinstance(payload,dict): raise FundingSourceError('SOURCE_MALFORMED')
                    txid = row['txid']
                    if not isinstance(txid,str) or re.fullmatch('[0-9a-f]{64}',txid) is None:
                        raise FundingSourceError('SOURCE_MALFORMED')
                    timestamp = _integer(payload['timestamp_ms'])
                    height = _integer(payload['block_number'])
                    _integer(payload['amount_units'])
                    if any(not isinstance(payload[key],str) or not payload[key] for key in ('from_address','to_address')):
                        raise FundingSourceError('SOURCE_MALFORMED')
                    if (payload['txid'] != txid or _integer(payload['log_index']) != _integer(row['log_index'])
                            or timestamp != _integer(row['timestamp_ms']) or timestamp > checkpoint or height > solid):
                        raise FundingSourceError('SOURCE_MALFORMED')
                    events.append(SourceEvent(_integer(row['rowid']),txid,timestamp,height,
                        payload['log_index'],payload['amount_units'],payload['from_address'],payload['to_address']))
                return SourceBatch(self.source_identity,after_rowid,events[-1].rowid if events else after_rowid,
                    maximum,checkpoint,heartbeat,solid,stable,reconciliation,healthy,
                    min(min(heartbeat,observed)+self.max_age_seconds*1000,
                        solid_ms+self.solid_head_max_age_seconds*1000),tuple(events),
                    _integer(observation['id']),int(balance),pending_since)
        except FundingSourceError:
            raise
        except (sqlite3.Error, OSError, ValueError, TypeError, KeyError, IndexError):
            raise FundingSourceError('SOURCE_UNAVAILABLE_OR_MALFORMED') from None
