"""Real domain records with a synthetic, immutable observer cut."""
from dataclasses import asdict, replace
from datetime import timedelta
from decimal import Decimal
import hashlib
import json

import pytest
from sqlalchemy import select, func

from app.integrations.tron.funding_source import ReserveCut
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.funding_scan_models import WalletFundingScanItem, WalletFundingScanState
from app.modules.wallet.models import WalletControl, WalletLedgerTransaction
from app.modules.wallet.incident_models import WalletIncident
from test_deposit_receipts import core, intent  # noqa: F401
from test_funding_coverage import coverage, register, verify  # noqa: F401


def digest_cut(cut, **changes):
    values = asdict(cut) | changes
    values.pop('digest', None)
    digest = hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return ReserveCut(**values, digest=digest)


@pytest.fixture
def monitor(core, coverage):
    from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
    from app.core.database import Base
    Base.metadata.create_all(core[1].kw['bind'])
    intent(core)
    register(core, coverage)
    core[0].ingest(core[2].value.txid, actor_id='fixture', defer_credit=True)
    assert verify(core, coverage)['status'] == 'VERIFIED'
    now = [core[5] + timedelta(seconds=3)]
    ms = int(now[0].timestamp()*1000)
    checkpoint = core[2].value.timestamp_ms
    cut = ReserveCut(coverage[0].source_identity, 1, 1, checkpoint, 103,
                     1000_000000, ms, ms+120000, True, '')
    class Source:
        source_identity = cut.source_identity
        value = digest_cut(cut)
        def read_reserve_cut(self):
            return self.value
    source = Source()
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = False
        session.add(WalletFundingScanState(id='global', source_identity=source.source_identity,
            cursor_rowid=1, source_max_rowid=1, checkpoint_ms=checkpoint, updated_at=now[0]))
        session.add(WalletFundingScanItem(txid=core[2].value.txid, state='PROCESSED',
            discovered_rowid=1, attempts=1, created_at=now[0], updated_at=now[0]))
    service = ManualReserveMonitor(core[1], source=source, official_config=coverage[0].config,
        activation_baseline_time=core[0].activation_baseline_time,
        activation_baseline_height=100, clock=lambda: now[0])
    return service, source, now


def test_unacknowledged_incident_escalates_even_when_source_fails(core, monitor):
    service, source, clock = monitor
    service.incidents.observe([dict(fingerprint='fixture:escalation',
        code='MANUAL_RESERVE_DEFICIT', severity='P0', subject_id='global')], complete=False)
    clock[0] += timedelta(seconds=301)
    def unavailable():
        raise RuntimeError('private-provider-error')
    source.read_reserve_cut = unavailable
    assert service.run_once()['status'] == 'BLOCKED'
    with core[1]() as session:
        incident = session.scalar(select(WalletIncident).where(
            WalletIncident.fingerprint == 'fixture:escalation'))
        assert incident.last_escalation_slot == 1
        version = incident.version
    service.run_once()
    with core[1]() as session:
        assert session.get(WalletIncident, incident.id).version == version


def test_boundary_stale_snapshot_is_resampled_before_opening_incident(core, monitor, monkeypatch):
    service, source, clock = monitor
    healthy = source.value
    source.value = digest_cut(healthy, healthy=False, fresh_until_ms=int(clock[0].timestamp()*1000)-1)
    waits=[]
    def refresh(delay):
        waits.append(delay)
        source.value = healthy
    monkeypatch.setattr('time.sleep', refresh, raising=False)
    result=service.run_once()
    assert result['complete'] is True
    assert waits == [0.2]
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletIncident).where(WalletIncident.code=='MANUAL_SOURCE_UNHEALTHY')) == 0


def test_discovery_retry_is_bounded_and_never_completes_on_pending_coverage(core, monitor, monkeypatch):
    service, source, clock = monitor
    calls=[]
    service.discovery_sync=lambda:calls.append('discover')
    source.value=digest_cut(source.value,checkpoint_ms=source.value.checkpoint_ms+1)
    monkeypatch.setattr('time.sleep',lambda delay:None,raising=False)
    result=service.review_once()
    assert result['codes']==['MANUAL_COVERAGE_PENDING']
    assert calls==['discover']*3


@pytest.mark.parametrize('new_event,boundary', [(False,False),(True,False),(False,True)])
def test_real_discovery_sync_aligns_empty_checkpoint_but_never_credits_new_events(core, monitor, new_event, boundary, monkeypatch):
    from app.integrations.tron.funding_source import SourceBatch, SourceEvent
    from app.modules.wallet.manual_discovery_sync import discovery_sync
    from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent
    service, source, clock=monitor
    before=source.value
    source.value=digest_cut(before,checkpoint_ms=before.checkpoint_ms+1,max_rowid=2 if new_event else 1)
    if boundary:
        replacement=source.value
        source.value=digest_cut(before,healthy=False,fresh_until_ms=int(clock[0].timestamp()*1000)-1)
        monkeypatch.setattr('time.sleep',lambda delay:setattr(source,'value',replacement))
    transfer=core[2].value.transfers[0]
    event=SourceEvent(2,'c'*64 if transfer.txid!='c'*64 else 'd'*64,transfer.timestamp_ms,transfer.block_number,0,
        transfer.amount_units,transfer.from_address,transfer.to_address)
    def batch(*,after_rowid,limit):
        cut=source.value
        return SourceBatch(cut.source_identity,after_rowid,cut.max_rowid,cut.max_rowid,
            cut.checkpoint_ms,cut.heartbeat_ms,cut.solid_block,True,'SOURCE_MATCHED',True,
            cut.fresh_until_ms,(event,) if new_event and after_rowid<2 else (),
            observation_id=cut.observation_id,balance_units=cut.balance_units)
    source.read_batch=batch
    with core[1].begin() as session:
        session.get(WalletControl,'global').withdrawals_paused=True
        ledger_before=session.scalar(select(func.count()).select_from(WalletLedgerTransaction))
        reserve_version=session.get(RedeemabilityReserve,'global').version
    service.discovery_sync=discovery_sync(core[1],source=source,official_config=service.config,
        baseline_time=service.baseline,baseline_height=service.baseline_height,clock=service.clock)
    callbacks=[]
    result=service.review_once(on_review=lambda session:callbacks.append('complete'))
    assert result['complete'] is (not new_event)
    assert callbacks==([] if new_event else ['complete'])
    with core[1]() as session:
        assert session.get(WalletControl,'global').withdrawals_paused
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction))==ledger_before
        if not new_event:
            assert session.get(RedeemabilityReserve,'global').version==reserve_version
        else:
            assert session.scalar(select(WalletFundingCoverageEvent.status).where(WalletFundingCoverageEvent.source_rowid==2))=='PENDING'


def test_manual_liquidity_deficit_warns_without_fabricating_balance_or_pausing(core, monitor):
    from dataclasses import replace
    service, source, clock = monitor
    service.reserve_policy = 'manual_liquidity'
    source.value = digest_cut(replace(source.value, balance_units=1_000000))
    result = service.run_once()
    assert result['status'] == 'PUBLISHED'
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused is False
        assert session.get(RedeemabilityReserve, 'global').eligible_usdt == Decimal('1')
        incident = session.scalar(select(WalletIncident).where(WalletIncident.code == 'MANUAL_BACKING_DEFICIT'))
        assert incident is not None and incident.condition_active and incident.severity == 'P1'


def test_escalation_failure_invalidates_reserve_without_publishing(core, monitor, monkeypatch):
    def unavailable():
        raise RuntimeError('private-database-error')
    monkeypatch.setattr(monitor[0].incidents, 'escalate', unavailable)
    result = monitor[0].run_once()
    assert result == dict(complete=False, status='BLOCKED', codes=['MANUAL_MONITOR_UNAVAILABLE'])
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, 'global').observed_at.year == 1970
        assert session.get(WalletControl, 'global').withdrawals_paused


def test_reserve_publication_then_retry_credits_once(core, monitor):
    result = monitor[0].run_once()
    assert result['complete'] and result['status'] == 'PUBLISHED'
    with core[1]() as session:
        reserve = session.get(RedeemabilityReserve, 'global')
        assert reserve.usdt_liability == Decimal('10')
        receipt = session.scalar(select(core[4]))
        assert receipt.status == 'REVIEW'
    assert core[0].retry_credit(receipt.id, actor_id='fixture')['status'] == 'CREDITED'
    assert core[0].retry_credit(receipt.id, actor_id='fixture')['status'] == 'CREDITED'
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(WalletLedgerTransaction)) == 1


@pytest.mark.parametrize('fault', ['source', 'stale', 'unhealthy', 'gap', 'retry', 'conflict', 'anomaly', 'deficit', 'pending'])
def test_unavailable_or_incomplete_reserve_pauses_without_publishing(core, coverage, monitor, fault):
    service, source, now = monitor
    if fault == 'source':
        def unavailable():
            raise RuntimeError('private-provider-error')
        source.read_reserve_cut = unavailable
    elif fault == 'stale':
        now[0] += timedelta(seconds=121)
    elif fault == 'unhealthy':
        source.value = digest_cut(source.value, healthy=False)
    elif fault == 'gap':
        source.value = digest_cut(source.value, max_rowid=2)
    elif fault == 'deficit':
        source.value = digest_cut(source.value, balance_units=9_000000)
    else:
        with core[1].begin() as session:
            if fault == 'retry':
                session.get(WalletFundingScanItem, core[2].value.txid).state = 'RETRY'
            elif fault == 'conflict':
                row = session.scalar(select(coverage[2]))
                row.status, row.conflict_at = 'CONFLICT', now[0]
            elif fault == 'anomaly':
                from app.modules.wallet.receipt_models import DepositReceiptAnomaly
                # Historical verification cannot hide a later receipt anomaly.
                session.add(DepositReceiptAnomaly(id='fixture-anomaly',
                    receipt_id=session.scalar(select(core[4].id)), observed_digest='f'*64,
                    reason_code='EVIDENCE_CONFLICT', observed_at=now[0]))
            elif fault == 'pending':
                session.get(RedeemabilityReserve, 'global').pending_payouts = 1
    result = service.run_once()
    if fault in ('gap', 'retry'):
        assert result['status'] == 'WAITING'
        with core[1]() as session:
            assert not session.get(WalletControl, 'global').withdrawals_paused
            assert session.get(RedeemabilityReserve, 'global').observed_at.year == 1970
        return
    assert not result['complete'] and result['status'] == 'BLOCKED'
    assert 'private-provider-error' not in str(result)
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(RedeemabilityReserve, 'global').outgoing_restricted
        assert session.scalar(select(WalletIncident)) is not None
        assert session.scalar(select(WalletLedgerTransaction)) is None


def test_source_change_between_reads_does_not_publish(core, monitor):
    source = monitor[1]
    original = source.value
    calls = []
    def changing():
        calls.append(1)
        return original if len(calls) == 1 else digest_cut(original, observation_id=2)
    source.read_reserve_cut = changing
    assert monitor[0].run_once()['status'] == 'RETRY'


def test_reserve_version_change_during_source_read_is_not_overwritten(core, monitor):
    source = monitor[1]
    read = source.read_reserve_cut
    changed = []
    def racing():
        if not changed:
            with core[1].begin() as session:
                reserve = session.get(RedeemabilityReserve, 'global')
                reserve.version += 1
                changed.append(reserve.version)
        return read()
    source.read_reserve_cut = racing
    assert monitor[0].run_once()['status'] == 'RETRY'
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, 'global').version == changed[0]


def test_existing_pause_is_never_cleared(core, monitor):
    with core[1].begin() as session:
        session.get(WalletControl, 'global').withdrawals_paused = True
        session.get(RedeemabilityReserve, 'global').outgoing_restricted = True
    assert monitor[0].run_once()['status'] == 'BLOCKED'
    with core[1]() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(RedeemabilityReserve, 'global').outgoing_restricted


def payout(core, monitor, *, status='CLAIMED', age=0, amount='10.000000', txid='e'*64, allocate=False, evidence_amount=None):
    from app.modules.wallet.manual_payout_models import ManualPayoutQuote, ManualPayoutOrder, ManualPayoutEvent
    from app.integrations.tron.finality import NETWORK, USDT_CONTRACT, POLICY, SOURCE_ID
    now = monitor[2][0]
    snapshot = dict(official_address=monitor[0].config.address, official_config_version=monitor[0].config.version,
        target_address=core[2].value.transfers[0].from_address, amount=amount, receive=amount,
        fee='0.000000', hold=amount, network=NETWORK, contract=USDT_CONTRACT, finality_policy=POLICY)
    with core[1].begin() as s:
        s.add(ManualPayoutQuote(id=txid[:36], user_id='alice', amount=Decimal(amount), snapshot=snapshot,
            digest='a'*64, created_at=now-timedelta(seconds=age), expires_at=now+timedelta(minutes=5)))
        s.flush()
        s.add(ManualPayoutOrder(id=txid[:36], quote_id=txid[:36], user_id='alice', amount=Decimal(amount),
            digest='b'*64, status=status, claimed_by='owner', claimed_at=now-timedelta(seconds=age),
            candidate_txid=txid if status in ('UNKNOWN', 'SETTLED') else None, created_at=now, updated_at=now))
        if status in ('CLAIMED', 'UNKNOWN'):
            s.get(RedeemabilityReserve, 'global').pending_payouts += 1
        if allocate:
            s.flush()
            s.add(ManualPayoutEvent(id=txid[:36], order_id=txid[:36], network=NETWORK,
                contract=USDT_CONTRACT, txid=txid, log_index=0, created_at=now,
                evidence=dict(policy=POLICY, source_id=SOURCE_ID, block_id='c'*64, block_number=102,
                    timestamp_ms=core[2].value.timestamp_ms, amount_units=int(Decimal(evidence_amount or amount)*1000000))))


def outflow(core, coverage, monitor, *, txid='e'*64, amount_units=10_000000):
    from app.integrations.tron.finality import NETWORK, USDT_CONTRACT, POLICY, SOURCE_ID
    source = monitor[1]
    facts = dict(txid=txid, log_index=0, amount_units=str(amount_units),
        from_address=monitor[0].config.address, to_address=core[2].value.transfers[0].from_address,
        block_number=102, timestamp_ms=core[2].value.timestamp_ms)
    rowid = source.value.max_rowid+1
    with core[1].begin() as s:
        s.add(coverage[2](id=txid[:36], source_identity=source.source_identity, source_rowid=rowid,
            **facts, facts_digest='a'*64, status='VERIFIED', created_at=monitor[2][0], verified_at=monitor[2][0],
            proof=dict(network=NETWORK, contract=USDT_CONTRACT, policy=POLICY, source_id=SOURCE_ID,
                block_id='c'*64, transaction_facts_digest=hashlib.sha256(json.dumps([facts], sort_keys=True).encode()).hexdigest())))
        s.add(WalletFundingScanItem(txid=txid, state='PROCESSED', discovered_rowid=rowid,
            attempts=1, created_at=monitor[2][0], updated_at=monitor[2][0]))
        state = s.get(WalletFundingScanState, 'global')
        state.cursor_rowid = state.source_max_rowid = rowid
    source.value = digest_cut(source.value, max_rowid=rowid)


@pytest.mark.parametrize('status', ['CLAIMED', 'UNKNOWN'])
@pytest.mark.parametrize('age', [0, 299, 300])
def test_pending_normal_progress_waits_until_uncertain(core, monitor, status, age):
    payout(core, monitor, status=status, age=age)
    result = monitor[0].run_once()
    assert result['status'] == ('BLOCKED' if age == 300 else 'WAITING')
    with core[1]() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        assert reserve.observed_at.year == 1970
        assert s.get(WalletControl, 'global').withdrawals_paused == (age == 300)


@pytest.mark.parametrize('field,value', [('observation_id', True), ('healthy', 1),
    ('balance_units', 2**256), ('max_rowid', True), ('digest', 'f'*64), ('solid_block', -1)])
def test_invalid_cut_cannot_take_unchanged_shortcut(core, monitor, field, value):
    assert monitor[0].run_once()['status'] == 'PUBLISHED'
    # Preserve the old digest: an invalid snapshot must never use the shortcut.
    monitor[1].value = replace(monitor[1].value, **{field:value})
    result = monitor[0].run_once()
    assert result['status'] == 'BLOCKED' and result['codes'] == ['MANUAL_SOURCE_INVALID']


@pytest.mark.parametrize('kind', ['unallocated', 'candidate', 'allocated', 'ahead', 'extra', 'amount'])
def test_outflow_allocation_requires_exact_settled_event(core, coverage, monitor, kind):
    if kind != 'unallocated':
        payout(core, monitor, status='UNKNOWN' if kind == 'candidate' else 'SETTLED',
            allocate=kind != 'candidate', amount='11.000000' if kind == 'amount' else '10.000000')
    if kind != 'ahead': outflow(core, coverage, monitor)
    if kind == 'extra': outflow(core, coverage, monitor, txid='f'*64)
    result = monitor[0].run_once()
    assert result['status'] == ('PUBLISHED' if kind == 'allocated' else 'BLOCKED')
    if kind == 'ahead': assert result['codes'] == ['MANUAL_SETTLEMENT_AHEAD_OF_CUT']


def test_source_io_outside_financial_transaction(core, monitor):
    from sqlalchemy import event
    active = set()
    engine = core[1].kw['bind']
    event.listen(engine, 'begin', lambda conn: active.add(conn))
    event.listen(engine, 'commit', lambda conn: active.discard(conn))
    event.listen(engine, 'rollback', lambda conn: active.discard(conn))
    original = monitor[1].read_reserve_cut
    calls = []
    def read():
        assert not active
        calls.append(1)
        return original()
    monitor[1].read_reserve_cut = read
    assert monitor[0].run_once()['status'] == 'PUBLISHED'
    assert len(calls) == 2


@pytest.mark.parametrize('fault', ['audit', 'outbox'])
def test_persistence_failure_rolls_back_all_effects(core, monitor, monkeypatch, fault):
    from sqlalchemy import event
    from app.modules.audit.models import AuditEvent
    from app.core.outbox import OutboxPublisher
    from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
    def fail(*a, **kw): raise RuntimeError('injected')
    with core[1]() as s:
        before = s.get(RedeemabilityReserve, 'global').version
    if fault == 'audit': event.listen(AuditEvent, 'before_insert', fail)
    else: monkeypatch.setattr(OutboxPublisher, 'enqueue', fail)
    try:
        assert monitor[0].run_once()['status'] == 'UNAVAILABLE'
    finally:
        if fault == 'audit': event.remove(AuditEvent, 'before_insert', fail)
    with core[1]() as s:
        assert s.get(RedeemabilityReserve, 'global').version == before
        assert not s.get(WalletControl, 'global').withdrawals_paused
        assert s.scalar(select(ManualReserveEvaluation)) is None


@pytest.mark.parametrize('state,age', [('DEAD', 0), ('FAILED', 300), ('PENDING', 300), ('PROCESSING', 300)])
def test_unhealthy_alert_delivery_blocks(core, monitor, state, age):
    from app.core.outbox import OutboxPublisher, OutboxEvent
    with core[1].begin() as s:
        ident = OutboxPublisher.enqueue(s, topic='wallet.alert', event_type='test', aggregate_type='wallet',
            aggregate_id='test', payload={}, now=monitor[2][0]-timedelta(seconds=age))
        s.flush()
        s.get(OutboxEvent, ident).status = state
    assert monitor[0].run_once()['codes'] == ['ALERT_DELIVERY_UNHEALTHY']


def test_report_integrity_checked_without_financial_transaction(core, monitor, monkeypatch):
    from app.modules.wallet.ledger_integrity import WalletLedgerIntegrityService
    calls = []
    def corrupt(self, day):
        calls.append(day)
        return {'balanced': False, 'missing_transaction_metadata': False}
    monkeypatch.setattr(WalletLedgerIntegrityService, 'check', corrupt)
    assert monitor[0].run_once()['codes'] == ['LEDGER_INTEGRITY']
    assert len(calls) == 1


def test_allocated_evidence_amount_must_equal_order_and_quote(core, coverage, monitor):
    payout(core, monitor, status='SETTLED', amount='11.000000', evidence_amount='10.000000', allocate=True)
    outflow(core, coverage, monitor)
    assert monitor[0].run_once()['codes'] == ['MANUAL_UNALLOCATED_OUTFLOW']


def test_baseline_excluded_history_does_not_count_as_eligible_coverage(core, coverage, monitor):
    # Fixture represents 100 older source rows excluded by activation, followed
    # by the one eligible deposit. Source row IDs are not eligible event counts.
    with core[1].kw['bind'].begin() as connection:
        connection.execute(coverage[2].__table__.update().values(source_rowid=101))
        connection.execute(WalletFundingScanItem.__table__.update().values(discovered_rowid=101))
        connection.execute(WalletFundingScanState.__table__.update().values(cursor_rowid=101, source_max_rowid=101))
    monitor[1].value = digest_cut(monitor[1].value, max_rowid=101)
    assert monitor[0].run_once()['status'] == 'PUBLISHED'


def test_incoming_numeric_obligation_must_match_verified_units(core, monitor):
    with core[1].kw['bind'].begin() as connection:
        connection.execute(core[4].__table__.update().values(amount=Decimal('1')))
    assert monitor[0].run_once()['codes'] == ['MANUAL_RECEIPT_OBLIGATION_MISSING']


def test_success_and_failure_never_clear_other_incidents(core, monitor):
    from app.modules.wallet.incidents import WalletIncidentService
    WalletIncidentService(core[1], now_factory=lambda: monitor[2][0]).observe([
        dict(fingerprint='other:test', code='OTHER', severity='P1', subject_id='other')], complete=False)
    assert monitor[0].run_once()['status'] == 'PUBLISHED'
    monitor[1].value = digest_cut(monitor[1].value, healthy=False)
    assert monitor[0].run_once()['status'] == 'BLOCKED'
    with core[1]() as s:
        row = s.scalar(select(WalletIncident).where(WalletIncident.fingerprint=='other:test'))
        assert row.condition_active and row.cleared_at is None


def test_unchanged_does_not_refresh_reserve(core, monitor):
    first = monitor[0].run_once()
    with core[1]() as s:
        row = s.get(RedeemabilityReserve, 'global')
        version, observed = row.version, row.observed_at
    monitor[2][0] += timedelta(seconds=30)
    second = monitor[0].run_once()
    assert second['status'] == 'UNCHANGED' and second['evaluation_id'] == first['evaluation_id']
    with core[1]() as s:
        row = s.get(RedeemabilityReserve, 'global')
        assert (row.version, row.observed_at) == (version, observed)


def test_checkpoint_only_progress_waits_then_publishes(core, monitor):
    with core[1].begin() as s:
        # Empty checkpoint jitter is not an aging monetary backlog.
        s.get(WalletFundingScanState, 'global').updated_at = monitor[2][0]-timedelta(hours=1)
    monitor[1].value = digest_cut(monitor[1].value, checkpoint_ms=monitor[1].value.checkpoint_ms+1)
    assert monitor[0].run_once()['status'] == 'WAITING'
    with core[1].begin() as s:
        assert not s.get(WalletControl, 'global').withdrawals_paused
        assert s.get(RedeemabilityReserve, 'global').observed_at.year == 1970
        s.get(WalletFundingScanState, 'global').checkpoint_ms = monitor[1].value.checkpoint_ms
    assert monitor[0].run_once()['status'] == 'PUBLISHED'


@pytest.mark.parametrize('kind', ['retry', 'pending'])
@pytest.mark.parametrize('age', [0, 299, 300])
def test_backlog_waits_and_ages_from_creation(core, coverage, monitor, kind, age):
    with core[1].kw['bind'].begin() as c:
        if kind == 'retry':
            c.execute(WalletFundingScanItem.__table__.update().values(state='RETRY',
                created_at=monitor[2][0]-timedelta(seconds=age), updated_at=monitor[2][0]))
        else:
            c.execute(coverage[2].__table__.update().values(status='PENDING', proof=None, verified_at=None,
                created_at=monitor[2][0]-timedelta(seconds=age)))
    result = monitor[0].run_once()
    assert result['status'] == ('BLOCKED' if age == 300 else 'WAITING')
    with core[1]() as s:
        assert s.get(WalletControl, 'global').withdrawals_paused == (age == 300)
        assert s.get(RedeemabilityReserve, 'global').observed_at.year == 1970


def test_more_than_fifty_transaction_batch_catches_up_without_unpause(core, coverage, monitor):
    from app.integrations.tron.finality import NETWORK, USDT_CONTRACT, POLICY, SOURCE_ID
    def discovered(start, end):
        with core[1].begin() as s:
            for rowid in range(start, end+1):
                txid = format(rowid, '064x')
                facts = dict(txid=txid, log_index=0, amount_units='1', from_address=monitor[0].config.address,
                    to_address=monitor[0].config.address, block_number=102, timestamp_ms=core[2].value.timestamp_ms)
                s.add(coverage[2](id=str(rowid), source_identity=monitor[1].source_identity, source_rowid=rowid,
                    **facts, facts_digest='a'*64, status='VERIFIED', created_at=monitor[2][0], verified_at=monitor[2][0],
                    proof=dict(network=NETWORK, contract=USDT_CONTRACT, policy=POLICY, source_id=SOURCE_ID,
                        block_id='c'*64, transaction_facts_digest=hashlib.sha256(json.dumps([facts], sort_keys=True).encode()).hexdigest())))
                s.add(WalletFundingScanItem(txid=txid, state='PROCESSED', discovered_rowid=rowid,
                    attempts=1, created_at=monitor[2][0], updated_at=monitor[2][0]))
            state = s.get(WalletFundingScanState, 'global')
            state.cursor_rowid, state.source_max_rowid = end, 61
    discovered(2, 51)
    monitor[1].value = digest_cut(monitor[1].value, max_rowid=61)
    assert monitor[0].run_once()['status'] == 'WAITING'
    with core[1]() as s:
        assert not s.get(WalletControl, 'global').withdrawals_paused
        assert s.get(RedeemabilityReserve, 'global').observed_at.year == 1970
    discovered(52, 61)
    assert monitor[0].run_once()['status'] == 'PUBLISHED'


@pytest.mark.parametrize('field', ['cursor_rowid', 'source_max_rowid', 'checkpoint_ms'])
def test_scan_state_ahead_of_source_is_conflict(core, monitor, field):
    with core[1].begin() as s:
        state = s.get(WalletFundingScanState, 'global')
        setattr(state, field, getattr(state, field)+1)
        if field == 'cursor_rowid': state.source_max_rowid = state.cursor_rowid
    assert monitor[0].run_once()['status'] == 'BLOCKED'


def test_discovery_backlog_ages_from_scan_progress(core, monitor):
    monitor[1].value = digest_cut(monitor[1].value, max_rowid=2)
    with core[1].begin() as s:
        s.get(WalletFundingScanState, 'global').updated_at = monitor[2][0]-timedelta(seconds=300)
    assert monitor[0].run_once()['codes'] == ['MANUAL_COVERAGE_BACKLOG']


def test_retry_catchup_preserves_funds_gate_and_recovers(core, monitor):
    with core[1].begin() as s:
        s.get(WalletFundingScanItem, core[2].value.txid).state = 'RETRY'
    assert monitor[0].run_once()['status'] == 'WAITING'
    with core[1].begin() as s:
        assert not s.get(WalletControl, 'global').withdrawals_paused
        assert s.scalar(select(WalletLedgerTransaction)) is None
        assert s.get(RedeemabilityReserve, 'global').observed_at.year == 1970
        s.get(WalletFundingScanItem, core[2].value.txid).state = 'PROCESSED'
    assert monitor[0].run_once()['status'] == 'PUBLISHED'


def test_waiting_preserves_prior_operator_pause(core, monitor):
    with core[1].begin() as s:
        s.get(WalletControl, 'global').withdrawals_paused = True
        s.get(RedeemabilityReserve, 'global').outgoing_restricted = True
    monitor[1].value = digest_cut(monitor[1].value, max_rowid=2)
    assert monitor[0].run_once()['status'] == 'WAITING'
    with core[1]() as s:
        assert s.get(WalletControl, 'global').withdrawals_paused
        assert s.get(RedeemabilityReserve, 'global').outgoing_restricted


@pytest.mark.parametrize('configured', [True, False])
def test_actual_delivery_configuration_persists_across_success_error_and_stale(core, monitor, configured):
    from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
    from app.modules.wallet.monitoring import WalletMonitoringService
    original, source, now = monitor
    writer = ManualReserveMonitor(core[1], source=source, official_config=original.config,
        activation_baseline_time=original.baseline, activation_baseline_height=original.baseline_height,
        clock=lambda: now[0], external_delivery_configured=configured)
    reader = WalletMonitoringService(core[1], now_factory=lambda: now[0])
    assert writer.run_once()['status'] == 'PUBLISHED'
    assert reader.status()['external_delivery_configured'] is configured
    assert reader.status()['stale'] is False
    now[0] += timedelta(seconds=121)
    assert reader.status()['stale'] is True
    assert reader.status()['external_delivery_configured'] is configured
    assert writer.run_once()['status'] == 'BLOCKED'
    state = reader.status()
    assert state['external_delivery_configured'] is configured
    assert state['last_error_code'] and state['stale']
    assert set(state) == {'last_attempt_at','last_success_at','last_error_code','stale',
                          'stale_after_seconds','external_delivery_configured'}
