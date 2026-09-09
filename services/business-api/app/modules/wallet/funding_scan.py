"""Durable discovery inbox; only the receipt domain can perform funding writes."""
from datetime import datetime, timezone

from sqlalchemy import func, select

from app.integrations.tron.funding_source import SourceBatch
from app.modules.ledger.reserve import lock_budget
from app.modules.wallet.funding_scan_models import WalletFundingScanItem, WalletFundingScanState
from app.modules.wallet.funding_coverage import discover as discover_coverage
from app.modules.wallet.models import WalletControl
from app.modules.wallet.safety import audit_write

ACTOR = 'wallet-funding-scan-worker'


class FundingScanService:
    def __init__(self, factory, *, source, receipts, activation_baseline_time, activation_baseline_height, clock,
                 coverage=None, defer_credit=False):
        if (not isinstance(activation_baseline_time,datetime) or activation_baseline_time.tzinfo is None
                or activation_baseline_time.utcoffset() is None or type(activation_baseline_height) is not int
                or activation_baseline_height < 0 or not callable(clock)):
            raise ValueError('explicit activation baseline and clock required')
        if type(defer_credit) is not bool or (defer_credit and coverage is None):
            raise ValueError('deferred scan requires explicit coverage service')
        if coverage is not None and coverage.source_identity != source.source_identity:
            raise ValueError('coverage source identity mismatch')
        self.factory, self.source, self.receipts, self.clock = factory, source, receipts, clock
        self.coverage, self.defer_credit = coverage, defer_credit
        self.activation_baseline_time = activation_baseline_time.astimezone(timezone.utc)
        self.activation_baseline_height = activation_baseline_height

    def _now(self):
        now = self.clock()
        if not isinstance(now,datetime) or now.tzinfo is None or now.utcoffset() is None:
            raise ValueError('aware server clock required')
        return now.astimezone(timezone.utc)

    @staticmethod
    def _lock(session):
        lock_budget(session)
        if session.get(WalletControl,'global',with_for_update=True) is None:
            raise ValueError('wallet control required')

    def _discover(self):
        with self.factory() as session:
            state = session.get(WalletFundingScanState,'global')
            expected = None if state is None else (state.source_identity,state.cursor_rowid,state.source_max_rowid,state.checkpoint_ms)
        cursor = expected[1] if expected else 0
        batch = self.source.read_batch(after_rowid=cursor,limit=100)
        if not isinstance(batch,SourceBatch) or batch.source_identity != self.source.source_identity or batch.after_rowid != cursor:
            raise ValueError('source identity mismatch')
        if expected and (batch.source_identity != expected[0] or batch.max_rowid < expected[2] or batch.checkpoint_ms < expected[3]):
            raise ValueError('source regression')
        with self.factory.begin() as session:
            self._lock(session)
            state = session.get(WalletFundingScanState,'global',with_for_update=True)
            actual = None if state is None else (state.source_identity,state.cursor_rowid,state.source_max_rowid,state.checkpoint_ms)
            if actual != expected:
                raise ValueError('concurrent cursor advancement')
            now = self._now()
            baseline_ms = int(self.activation_baseline_time.timestamp()*1000)
            newest = {}
            eligible_events = []
            for event in batch.events:
                if event.timestamp_ms >= baseline_ms and event.block_number > self.activation_baseline_height:
                    newest[event.txid] = event.rowid
                    eligible_events.append(event)
            if self.coverage is not None:
                discover_coverage(session, source_identity=batch.source_identity, events=eligible_events, actor_id=ACTOR, now=now)
            for txid,rowid in newest.items():
                item = session.get(WalletFundingScanItem,txid)
                if item is None:
                    session.add(WalletFundingScanItem(txid=txid,state='PENDING',discovered_rowid=rowid,
                        attempts=0,created_at=now,updated_at=now))
                elif rowid > item.discovered_rowid:
                    item.state,item.discovered_rowid,item.last_reason,item.updated_at = 'PENDING',rowid,None,now
            current = (batch.source_identity,batch.next_rowid,batch.max_rowid,batch.checkpoint_ms)
            if state is None:
                session.add(WalletFundingScanState(id='global',source_identity=batch.source_identity,
                    cursor_rowid=batch.next_rowid,source_max_rowid=batch.max_rowid,checkpoint_ms=batch.checkpoint_ms,updated_at=now))
            elif current != actual:
                state.cursor_rowid,state.source_max_rowid,state.checkpoint_ms,state.updated_at = batch.next_rowid,batch.max_rowid,batch.checkpoint_ms,now
            if current != actual:
                audit_write(session,ACTOR,'global','wallet.funding_scan_discovered','FUNDING_SCAN_DISCOVERED')
            session.flush()
        return batch

    def _finish(self,txid,version,success):
        with self.factory.begin() as session:
            self._lock(session)
            item = session.get(WalletFundingScanItem,txid,with_for_update=True)
            # Another scan can discover a later log during receipt verification.
            # Never mark that newer generation processed using older evidence.
            if item is None or item.discovered_rowid != version or item.state == 'PROCESSED':
                return
            item.attempts += 1
            item.state = 'PROCESSED' if success else 'RETRY'
            item.last_reason = None if success else 'RECEIPT_INGEST_FAILED'
            item.updated_at = self._now()
            audit_write(session,ACTOR,txid,'wallet.funding_scan_processed' if success else 'wallet.funding_scan_retry',
                'FUNDING_SCAN_PROCESSED' if success else 'RECEIPT_INGEST_FAILED')

    def run_once(self, *, funds_enabled):
        if type(funds_enabled) is not bool:
            raise ValueError('explicit funds gate required')
        processed = 0
        try:
            batch = self._discover()
        except Exception:
            return {'status':'SOURCE_UNAVAILABLE','source_healthy':False,'processed':0}
        result = {'status':'FUNDS_DISABLED' if not funds_enabled else 'SOURCE_UNHEALTHY',
            'source_healthy':batch.healthy,'cursor_rowid':batch.next_rowid,'processed':0}
        if not funds_enabled or not batch.healthy:
            return result
        with self.factory() as session:
            pending = list(session.execute(select(WalletFundingScanItem.txid,WalletFundingScanItem.discovered_rowid)
                .where(WalletFundingScanItem.state.in_(('PENDING','RETRY')))
                .order_by(WalletFundingScanItem.updated_at,WalletFundingScanItem.txid).limit(50)))
        for txid,version in pending:
            # Recheck current observer health between network operations. A new
            # failed observer run must not let the rest of an old batch proceed.
            try:
                health = self.source.read_batch(after_rowid=batch.next_rowid,limit=1)
                healthy = (isinstance(health,SourceBatch) and health.source_identity == batch.source_identity
                    and health.max_rowid >= batch.max_rowid and health.checkpoint_ms >= batch.checkpoint_ms
                    and health.healthy and health.heartbeat_ms <= self._now().timestamp()*1000 <= health.fresh_until_ms)
            except Exception:
                healthy = False
            if not healthy:
                result['status'],result['source_healthy'] = 'SOURCE_UNHEALTHY',False
                break
            try:
                if self.defer_credit:
                    self.receipts.ingest(txid,actor_id=ACTOR,defer_credit=True)
                else:
                    self.receipts.ingest(txid,actor_id=ACTOR)
                success = (self.coverage is None or
                    self.coverage.verify_transaction(txid,actor_id=ACTOR)['status'] == 'VERIFIED')
            except Exception:
                success = False
            try:
                self._finish(txid,version,success)
            except Exception:
                result['status'] = 'INBOX_UPDATE_FAILED'
                break
            processed += int(success)
        else:
            result['status'] = 'OK'
        result['processed'] = processed
        return result

    def status(self):
        with self.factory() as session:
            state = session.get(WalletFundingScanState,'global')
            counts = dict(session.execute(select(WalletFundingScanItem.state,func.count())
                .group_by(WalletFundingScanItem.state)).all())
            return {'cursor_rowid':state.cursor_rowid if state else 0,
                'pending':counts.get('PENDING',0),'retry':counts.get('RETRY',0),'processed':counts.get('PROCESSED',0)}
