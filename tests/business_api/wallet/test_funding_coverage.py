from dataclasses import replace
from datetime import timedelta

import pytest
from sqlalchemy import select, func

from test_deposit_receipts import core


@pytest.fixture
def coverage(core):
    from app.modules.wallet.funding_coverage import FundingCoverageService, discover
    from app.modules.wallet.funding_coverage_models import WalletFundingCoverageEvent
    from app.core.database import Base
    from app.modules.wallet.funding import OfficialFundingConfig
    Base.metadata.create_all(core[1].kw['bind'])
    service = FundingCoverageService(core[1], finality_adapter=core[2],
        official_config=OfficialFundingConfig(core[2].value.transfers[0].to_address, 'fixture-v1'),
        clock=lambda: core[5]+timedelta(seconds=3))
    return service, discover, WalletFundingCoverageEvent


def register(core, coverage, transfers=None):
    from app.integrations.tron.funding_source import SourceEvent
    transfers = transfers if transfers is not None else core[2].value.transfers
    events = tuple(SourceEvent(i+1,t.txid,t.timestamp_ms,t.block_number,t.log_index,
        t.amount_units,t.from_address,t.to_address) for i,t in enumerate(transfers))
    with core[1].begin() as session:
        coverage[1](session, source_identity=coverage[0].source_identity, events=events,
            actor_id='coverage-worker', now=core[5])


def verify(core, coverage):
    return coverage[0].verify_transaction(core[2].value.txid, actor_id='coverage-worker')


def test_discovery_idempotent(core, coverage):
    register(core,coverage)
    register(core,coverage)
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(coverage[2])) == 1


def test_requires_incoming_obligation(core, coverage):
    register(core,coverage)
    assert verify(core,coverage)['status'] == 'PENDING'
    core[0].ingest(core[2].value.txid, actor_id='worker', defer_credit=True)
    assert verify(core,coverage)['status'] == 'VERIFIED'
    assert verify(core,coverage)['status'] == 'VERIFIED'


@pytest.mark.parametrize('change', ['missing','amount'])
def test_conflict_is_permanent(core, coverage, change):
    register(core,coverage)
    original=core[2].value
    core[2].value=replace(original,transfers=() if change=='missing' else
        (replace(original.transfers[0],amount_units=1),))
    assert verify(core,coverage)['status'] == 'CONFLICT'
    core[2].value=original
    assert verify(core,coverage)['status'] == 'CONFLICT'


def test_extra_log_waits_for_discovery(core, coverage):
    register(core,coverage)
    original=core[2].value
    core[2].value=replace(original,transfers=original.transfers+
        (replace(original.transfers[0],log_index=1),))
    core[0].ingest(original.txid, actor_id='worker', defer_credit=True)
    assert verify(core,coverage)['status'] == 'PENDING'
    register(core,coverage)
    assert verify(core,coverage)['status'] == 'VERIFIED'


def test_discovery_rollback(core, coverage):
    from app.integrations.tron.funding_source import SourceEvent
    t=core[2].value.transfers[0]
    with pytest.raises(RuntimeError):
        with core[1].begin() as s:
            coverage[1](s,source_identity=coverage[0].source_identity,
                events=[SourceEvent(1,t.txid,t.timestamp_ms,t.block_number,t.log_index,t.amount_units,t.from_address,t.to_address)],
                actor_id='worker',now=core[5])
            raise RuntimeError('rollback')
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(coverage[2])) == 0


def test_provider_called_without_transaction(core, coverage):
    from sqlalchemy import event
    register(core,coverage)
    active=set()
    engine=core[1].kw['bind']
    event.listen(engine,'begin',lambda conn: active.add(conn))
    event.listen(engine,'rollback',lambda conn: active.discard(conn))
    event.listen(engine,'commit',lambda conn: active.discard(conn))
    original=core[2].transaction_evidence
    def fetch(txid):
        assert not active
        return original(txid)
    core[2].transaction_evidence=fetch
    assert verify(core,coverage)['status']=='PENDING'


def test_verification_audit_failure_rolls_back(core, coverage, monkeypatch):
    import app.modules.wallet.funding_coverage as module
    register(core,coverage)
    core[0].ingest(core[2].value.txid,actor_id='worker',defer_credit=True)
    def fail(*args):
        raise RuntimeError('atomic failure')
    monkeypatch.setattr(module,'audit_write',fail)
    with pytest.raises(RuntimeError):
        verify(core,coverage)
    with core[1]() as s:
        row=s.scalar(select(coverage[2]))
        assert row.status=='PENDING' and row.proof is None and row.verified_at is None


def test_outgoing_proves_only_chain_facts(core, coverage):
    t=core[2].value.transfers[0]
    core[2].value=replace(core[2].value,transfers=(replace(t,from_address=t.to_address,to_address=t.from_address),))
    register(core,coverage)
    assert verify(core,coverage)['status']=='VERIFIED'
    with core[1]() as s:
        assert s.scalar(select(func.count()).select_from(core[4]))==0


def test_provider_error_safe(core, coverage):
    register(core,coverage)
    def fail(txid):
        raise RuntimeError('sensitive provider data')
    core[2].transaction_evidence=fail
    result=verify(core,coverage)
    assert result['status']=='UNAVAILABLE'
    assert 'sensitive' not in str(result)


@pytest.mark.parametrize('field', ['policy','network','source_id','contract'])
def test_wrong_evidence_domain_unavailable(core,coverage,field):
    register(core,coverage)
    core[2].value=replace(core[2].value,**{field:'invalid'})
    assert verify(core,coverage)['status']=='UNAVAILABLE'


def test_discovery_changed_facts_conflicts(core,coverage):
    register(core,coverage)
    register(core,coverage,[replace(core[2].value.transfers[0],amount_units=99)])
    assert verify(core,coverage)['status']=='CONFLICT'


def test_set_changed_during_fetch_waits(core,coverage):
    register(core,coverage)
    e=core[2].value
    new=replace(e,transfers=e.transfers+(replace(e.transfers[0],log_index=1),))
    def fetch(txid):
        register(core,coverage,new.transfers)
        return new
    core[2].transaction_evidence=fetch
    assert verify(core,coverage)['status']=='PENDING'


def test_verified_facts_and_proof_immutable(core,coverage):
    register(core,coverage)
    core[0].ingest(core[2].value.txid,actor_id='worker',defer_credit=True)
    assert verify(core,coverage)['status']=='VERIFIED'
    with pytest.raises(ValueError):
        with core[1].begin() as s:
            s.scalar(select(coverage[2])).amount_units='1'
    with pytest.raises(ValueError):
        with core[1].begin() as s:
            s.scalar(select(coverage[2])).proof={'fake':True}


def test_stale_finality_waits(core,coverage):
    register(core,coverage)
    core[2].value=replace(core[2].value,observed_at=core[5]-timedelta(seconds=121))
    assert verify(core,coverage)['status']=='UNAVAILABLE'


def test_verified_then_changed_source_is_permanent_conflict(core,coverage):
    register(core,coverage)
    core[0].ingest(core[2].value.txid,actor_id='worker',defer_credit=True)
    assert verify(core,coverage)['status']=='VERIFIED'
    core[2].value=replace(core[2].value,transfers=())
    assert verify(core,coverage)['status']=='CONFLICT'
    with core[1]() as s:
        row=s.scalar(select(coverage[2]))
        assert row.proof is not None and row.verified_at is not None and row.conflict_at is not None


def outgoing(core):
    t=core[2].value.transfers[0]
    core[2].value=replace(core[2].value,transfers=(replace(t,from_address=t.to_address,to_address=t.from_address),))


def test_missing_control_blocks_proof(core,coverage):
    from app.modules.wallet.models import WalletControl
    outgoing(core)
    register(core,coverage)
    with core[1].begin() as s:
        s.delete(s.get(WalletControl,'global'))
    assert verify(core,coverage)['status']=='UNAVAILABLE'
    with core[1]() as s:
        assert s.scalar(select(coverage[2])).proof is None


def test_changed_verified_block_conflicts(core,coverage):
    outgoing(core)
    register(core,coverage)
    assert verify(core,coverage)['status']=='VERIFIED'
    e=core[2].value
    core[2].value=replace(e,block_id='f'*64,transfers=(replace(e.transfers[0],block_id='f'*64),))
    assert verify(core,coverage)['status']=='CONFLICT'


def test_discovery_and_conflict_invalidate_once(core,coverage):
    from app.modules.ledger.reserve import RedeemabilityReserve
    from app.modules.wallet.models import WalletControl
    with core[1]() as s:
        initial=s.get(RedeemabilityReserve,'global').version
    register(core,coverage)
    with core[1]() as s:
        row=s.get(RedeemabilityReserve,'global')
        assert row.version>initial
        version=row.version
        assert s.get(WalletControl,'global').withdrawals_paused
    register(core,coverage)
    with core[1]() as s:
        assert s.get(RedeemabilityReserve,'global').version==version
    # A new reserve publication may occur between discovery and contradiction.
    with core[1].begin() as s:
        s.get(RedeemabilityReserve,'global').observed_at=core[5]
    core[2].value=replace(core[2].value,transfers=())
    assert verify(core,coverage)['status']=='CONFLICT'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve,'global').version>version
        version=s.get(RedeemabilityReserve,'global').version
    assert verify(core,coverage)['status']=='CONFLICT'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve,'global').version==version


@pytest.mark.parametrize('component',['transaction','head'])
def test_untyped_evidence_rejected(core,coverage,component):
    from types import SimpleNamespace
    outgoing(core)
    register(core,coverage)
    e=core[2].value
    core[2].value=(SimpleNamespace(**vars(e)) if component=='transaction' else
        replace(e,solid_head=SimpleNamespace(**vars(e.solid_head))))
    assert verify(core,coverage)['status']=='UNAVAILABLE'


def test_normal_head_growth_preserves_proof(core,coverage):
    outgoing(core)
    register(core,coverage)
    assert verify(core,coverage)['status']=='VERIFIED'
    e=core[2].value
    core[2].value=replace(e,observed_at=core[5]+timedelta(seconds=1),
        solid_head=replace(e.solid_head,height=104,block_id='e'*64,observed_at=core[5]+timedelta(seconds=1)))
    assert verify(core,coverage)['status']=='VERIFIED'


def test_verified_transaction_extra_log_conflicts(core,coverage):
    from app.modules.ledger.reserve import RedeemabilityReserve
    outgoing(core)
    register(core,coverage)
    assert verify(core,coverage)['status']=='VERIFIED'
    with core[1].begin() as s:
        s.get(RedeemabilityReserve,'global').observed_at=core[5]
    e=core[2].value
    core[2].value=replace(e,transfers=e.transfers+(replace(e.transfers[0],log_index=1),))
    assert verify(core,coverage)['status']=='CONFLICT'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve,'global').observed_at.year==1970


def test_verified_incoming_anomaly_conflicts(core,coverage):
    from app.modules.wallet.receipt_models import DepositReceiptAnomaly
    register(core,coverage)
    core[0].ingest(core[2].value.txid,actor_id='worker',defer_credit=True)
    assert verify(core,coverage)['status']=='VERIFIED'
    with core[1].begin() as s:
        receipt=s.scalar(select(core[4]))
        s.add(DepositReceiptAnomaly(id='anomaly',receipt_id=receipt.id,observed_digest='f'*64,
            reason_code='EVIDENCE_CHANGED',observed_at=core[5]))
    assert verify(core,coverage)['status']=='CONFLICT'


def test_verified_incoming_missing_liability_invalidates(core,coverage,monkeypatch):
    from app.modules.ledger.reserve import RedeemabilityReserve
    register(core,coverage)
    core[0].ingest(core[2].value.txid,actor_id='worker',defer_credit=True)
    assert verify(core,coverage)['status']=='VERIFIED'
    with core[1].begin() as s:
        s.get(RedeemabilityReserve,'global').observed_at=core[5]
    monkeypatch.setattr(coverage[0],'_liability',lambda *args: False)
    assert verify(core,coverage)['status']=='PENDING'
    with core[1]() as s:
        assert s.get(RedeemabilityReserve,'global').observed_at.year==1970


def test_legacy_proof_without_full_digest_unavailable(core,coverage):
    from sqlalchemy import update
    outgoing(core)
    register(core,coverage)
    assert verify(core,coverage)['status']=='VERIFIED'
    with core[1].begin() as s:
        row=s.scalar(select(coverage[2]))
        proof=dict(row.proof)
        proof.pop('transaction_facts_digest',None)
        # Fixture simulates an old persisted proof, bypassing ORM immutability.
        s.execute(update(coverage[2]).where(coverage[2].id==row.id).values(proof=proof))
    assert verify(core,coverage)['status']=='UNAVAILABLE'
