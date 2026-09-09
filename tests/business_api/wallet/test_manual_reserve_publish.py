from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext
import hashlib
import json

import pytest
from sqlalchemy import create_engine, event, select, update, delete

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent, OutboxPublisher
from app.modules.audit.models import AuditEvent
from app.modules.ledger.manual_reserve import publish_manual_reserve
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.ledger.manual_payout_reserve import mark_manual_payout_pending

NOW = datetime(2026, 9, 7, tzinfo=timezone.utc)


@pytest.fixture
def factory():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    yield create_session_factory(engine)
    engine.dispose()


def args(**overrides):
    values = dict(expected_version=None, eligible_usdt=Decimal('10'), usdt_liability=Decimal('10'),
        pending_payouts=0, observed_at=NOW, now=NOW, source_identity='a'*64,
        observation_id=1, cut_digest='b'*64, evidence={'heartbeat_ms': int(NOW.timestamp()*1000),
            'fresh_until_ms': int(NOW.timestamp()*1000)+120000, 'healthy': True},
        actor_id='monitor', idempotency_key='publish-1')
    values.update(overrides)
    if 'evidence' not in overrides:
        with localcontext() as ctx:
            ctx.prec = 80
            amount = values['eligible_usdt']
            units = int(amount*1000000) if isinstance(amount, Decimal) and amount.is_finite() else 10000000
        ms = int(values['observed_at'].replace(tzinfo=timezone.utc).timestamp()*1000)
        values['evidence'] = dict(max_rowid=0, checkpoint_ms=ms, solid_block=100,
            heartbeat_ms=ms, fresh_until_ms=ms+120000, balance_units=units, healthy=True)
    if 'cut_digest' not in overrides:
        cut = dict(source_identity=values['source_identity'], observation_id=values['observation_id'], **values['evidence'])
        values['cut_digest'] = hashlib.sha256(json.dumps(cut, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    return values


def test_bootstrap_and_replay_after_invalidation(factory):
    with factory.begin() as s:
        first = publish_manual_reserve(s, **args())
        assert first.result_version == 1
    with factory.begin() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        mark_manual_payout_pending(reserve)
    with factory.begin() as s:
        replay = publish_manual_reserve(s, **args(now=NOW+timedelta(days=1)))
        assert replay.id == first.id
        reserve = s.get(RedeemabilityReserve, 'global')
        assert reserve.version == 2 and reserve.pending_payouts == 1
        assert reserve.observed_at.year == 1970
        assert len(list(s.scalars(select(AuditEvent)))) == 1
        assert len(list(s.scalars(select(OutboxEvent)))) == 1


def test_manual_liquidity_publication_retains_actual_deficit(factory):
    with factory.begin() as session:
        result = publish_manual_reserve(session, **args(eligible_usdt=Decimal('1')), policy='manual_liquidity')
        assert result.evidence['reserve_policy'] == 'manual_liquidity'
        assert Decimal(result.evidence['backing_deficit']) == Decimal('9')
        assert session.get(RedeemabilityReserve, 'global').eligible_usdt == Decimal('1')
    with factory.begin() as session:
        with pytest.raises(ValueError):
            publish_manual_reserve(session, **args(eligible_usdt=Decimal('1')))


@pytest.mark.parametrize('overrides', [
    {'eligible_usdt': Decimal('9.999999')}, {'eligible_usdt': 10.0},
    {'eligible_usdt': Decimal('0.0000001')}, {'eligible_usdt': Decimal('NaN')},
    {'eligible_usdt': Decimal('Infinity')}, {'eligible_usdt': Decimal('-1')},
    {'eligible_usdt': Decimal('1000000000000000000000000')},
    {'usdt_liability': 0.0}, {'pending_payouts': True}, {'pending_payouts': 1},
    {'expected_version': 0}, {'expected_version': True}, {'expected_version': 1},
    {'observation_id': 0}, {'source_identity': 'bad'}, {'cut_digest': 'B'*64},
    {'evidence': {'token': 'secret'}}, {'evidence': {'heartbeat_ms': 0}},
    {'observed_at': NOW.replace(tzinfo=None)}, {'now': NOW.replace(tzinfo=None)},
    {'now': NOW-timedelta(microseconds=1)}, {'now': NOW+timedelta(seconds=120,microseconds=1)},
])
def test_invalid_publications_leave_no_facts(factory, overrides):
    with pytest.raises(ValueError), factory.begin() as s:
        publish_manual_reserve(s, **args(**overrides))
    with factory() as s:
        assert s.get(RedeemabilityReserve, 'global') is None
        assert list(s.scalars(select(ManualReserveEvaluation))) == []


def test_exact_six_decimal_maximum_and_freshness_boundary(factory, monkeypatch):
    import app.modules.ledger.manual_reserve as gateway
    maximum = Decimal('999999999999999999999999.999999')
    monkeypatch.setattr(gateway, 'caibi_liability', lambda s: Decimal('0.000001'))
    with localcontext() as ctx:
        ctx.prec = 8
        with factory.begin() as s:
            result = publish_manual_reserve(s, **args(eligible_usdt=maximum,
                usdt_liability=Decimal('999999999999999999999999.999998'), now=NOW+timedelta(seconds=120)))
            assert result.evidence['eligible_usdt'] == str(maximum)


def test_caibi_is_in_coverage(factory, monkeypatch):
    import app.modules.ledger.manual_reserve as gateway
    monkeypatch.setattr(gateway, 'caibi_liability', lambda s: Decimal('0.01'))
    with pytest.raises(ValueError, match='coverage'), factory.begin() as s:
        publish_manual_reserve(s, **args())


def test_real_caibi_accounts_include_hold_escrow_exclude_platform(factory):
    from app.modules.ledger.models import LedgerEntry
    with factory.begin() as s:
        for index, (account, amount) in enumerate([
            ('user', '2.00'), ('hold', '3.00'), ('escrow', '4.00'),
            ('issuance', '-9.00'), ('PLATFORM_FEE', '99.00'), ('PLATFORM_CLEARING', '99.00')]):
            s.add(LedgerEntry(id=str(index), transaction_id='test-transaction', account_id=account,
                asset='CAIBI', amount=Decimal(amount), created_at=NOW))
    with pytest.raises(ValueError, match='coverage'), factory.begin() as s:
        publish_manual_reserve(s, **args(eligible_usdt=Decimal('18.999999')))
    with factory.begin() as s:
        result = publish_manual_reserve(s, **args(eligible_usdt=Decimal('19.000000')))
        assert Decimal(result.evidence['caibi_liability']) == Decimal('9')


def test_claim_invalidates_optimistic_cut_and_pending_cannot_refresh(factory):
    with factory.begin() as s:
        publish_manual_reserve(s, **args())
    with factory.begin() as s:
        mark_manual_payout_pending(s.get(RedeemabilityReserve, 'global'))
    for version, pending in [(1, 0), (2, 0), (2, 1)]:
        with pytest.raises(ValueError), factory.begin() as s:
            publish_manual_reserve(s, **args(expected_version=version, pending_payouts=pending,
                idempotency_key='claim-cut', observation_id=2))
    with factory() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        assert reserve.version == 2 and reserve.observed_at.year == 1970


def test_preloaded_identity_map_cannot_hide_changed_version(factory):
    with factory.begin() as s:
        publish_manual_reserve(s, **args())
    with factory() as stale:
        cached = stale.get(RedeemabilityReserve, 'global')
        assert cached.version == 1
        with factory.begin() as current:
            mark_manual_payout_pending(current.get(RedeemabilityReserve, 'global'))
        with pytest.raises(ValueError, match='version changed'):
            publish_manual_reserve(stale, **args(expected_version=1, idempotency_key='stale-cache', observation_id=2))
        stale.rollback()


def test_staged_caibi_fact_is_checked_after_budget_lock(factory, monkeypatch):
    import app.modules.ledger.manual_reserve as gateway
    from app.modules.ledger.models import LedgerEntry
    original = gateway.lock_budget
    calls = []
    def locked(session):
        result = original(session)
        calls.append('lock')
        return result
    monkeypatch.setattr(gateway, 'lock_budget', locked)
    with pytest.raises(ValueError, match='coverage'), factory.begin() as s:
        event.listen(s, 'before_flush', lambda *a: calls.append('flush'))
        s.add(LedgerEntry(id='staged', transaction_id='test-transaction', account_id='escrow',
            asset='CAIBI', amount=Decimal('0.01'), created_at=NOW))
        publish_manual_reserve(s, **args())
    assert calls[:2] == ['lock', 'flush']


def test_source_history_survives_invalidation_and_source_switch(factory):
    with factory.begin() as s:
        publish_manual_reserve(s, **args(observation_id=5))
    with factory.begin() as s:
        publish_manual_reserve(s, **args(expected_version=1, source_identity='c'*64,
            observation_id=1, idempotency_key='other-source'))
    with factory.begin() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        reserve.observed_at = NOW-timedelta(days=1)
        reserve.version += 1
    old = NOW-timedelta(seconds=1)
    for changes in ({'observation_id': 4}, {'observation_id': 6, 'observed_at': old}):
        with pytest.raises(ValueError, match='regressed'), factory.begin() as s:
            publish_manual_reserve(s, **args(**({'expected_version': 3, 'idempotency_key': 'rollback'} | changes)))


@pytest.mark.parametrize('source', [
    {'heartbeat_ms': 2**63, 'fresh_until_ms': 1, 'healthy': True},
    {'heartbeat_ms': 1, 'fresh_until_ms': 1, 'healthy': False},
    {'heartbeat_ms': 1, 'fresh_until_ms': 1, 'healthy': True, 'balance_units': str(2**256)},
])
def test_bounded_source_cut(factory, source):
    with pytest.raises(ValueError), factory.begin() as s:
        publish_manual_reserve(s, **args(evidence=source))


@pytest.mark.parametrize('kind', ['incomplete', 'mismatch', 'digest', 'actor'])
def test_source_cut_integrity(factory, kind):
    values = args()
    if kind == 'incomplete':
        del values['evidence']['solid_block']
    elif kind == 'mismatch':
        values['eligible_usdt'] = Decimal('11')
    elif kind == 'digest':
        values['cut_digest'] = 'c'*64
    else:
        values['actor_id'] = 'monitor\nsecret'
    with pytest.raises(ValueError), factory.begin() as s:
        publish_manual_reserve(s, **values)


@pytest.mark.parametrize('field', ['max_rowid', 'checkpoint_ms', 'solid_block'])
def test_source_progress_cannot_regress(factory, field):
    cut = args()['evidence'] | {'max_rowid': 10}
    with factory.begin() as s:
        publish_manual_reserve(s, **args(evidence=cut))
    cut = cut | {field: cut[field]-1}
    with pytest.raises(ValueError, match='regressed'), factory.begin() as s:
        publish_manual_reserve(s, **args(evidence=cut, observation_id=2, expected_version=1, idempotency_key='regress'))


def test_version_pending_restriction_and_historical_source(factory):
    with factory.begin() as s:
        publish_manual_reserve(s, **args(observation_id=5))
    with factory.begin() as s:
        reserve = s.get(RedeemabilityReserve, 'global')
        reserve.outgoing_restricted = True
        reserve.version += 1
    for overrides in ({'expected_version': 1}, {'expected_version': None},
                      {'expected_version': 2, 'pending_payouts': 1},
                      {'expected_version': 2, 'observation_id': 4}):
        with pytest.raises(ValueError), factory.begin() as s:
            publish_manual_reserve(s, **args(**({'idempotency_key': 'next', 'observation_id': 6} | overrides)))
    with factory.begin() as s:
        result = publish_manual_reserve(s, **args(expected_version=2, idempotency_key='next', observation_id=6))
        assert result.result_version == 3
        assert s.get(RedeemabilityReserve, 'global').outgoing_restricted is True


def test_idempotency_conflict(factory):
    with factory.begin() as s:
        publish_manual_reserve(s, **args())
    with pytest.raises(ValueError, match='idempotency'), factory.begin() as s:
        publish_manual_reserve(s, **args(eligible_usdt=Decimal('11')))


@pytest.mark.parametrize('target', ['audit', 'outbox'])
def test_atomic_rollback(factory, monkeypatch, target):
    def fail(*a, **kw):
        raise RuntimeError('injected persistence failure')
    if target == 'audit':
        event.listen(AuditEvent, 'before_insert', fail)
    else:
        monkeypatch.setattr(OutboxPublisher, 'enqueue', fail)
    try:
        with pytest.raises(RuntimeError), factory.begin() as s:
            publish_manual_reserve(s, **args())
    finally:
        if target == 'audit':
            event.remove(AuditEvent, 'before_insert', fail)
    with factory() as s:
        assert s.get(RedeemabilityReserve, 'global') is None
        assert list(s.scalars(select(ManualReserveEvaluation))) == []
        assert list(s.scalars(select(AuditEvent))) == []
        assert list(s.scalars(select(OutboxEvent))) == []


@pytest.mark.parametrize('operation', ['update', 'delete', 'bulk_update', 'bulk_delete'])
def test_evaluation_immutable(factory, operation):
    with factory.begin() as s:
        publish_manual_reserve(s, **args())
    with pytest.raises(ValueError, match='append-only'), factory.begin() as s:
        row = s.scalar(select(ManualReserveEvaluation))
        if operation == 'update': row.cut_digest = 'c'*64
        elif operation == 'delete': s.delete(row)
        elif operation == 'bulk_update': s.execute(update(ManualReserveEvaluation).values(cut_digest='c'*64))
        else: s.execute(delete(ManualReserveEvaluation))
