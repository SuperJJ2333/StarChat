from datetime import datetime, timedelta, timezone
from importlib.util import find_spec

import pytest
from sqlalchemy import create_engine, select

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState
from app.modules.wallet.models import WalletControl, WalletSafetyState
from app.integrations.tron.message_signature import address_from_public_key


def test_funding_module_exists():
    assert find_spec('app.modules.wallet.funding') is not None, 'deposit intent service missing'


@pytest.fixture
def core():
    from coincurve import PrivateKey
    from app.modules.wallet.funding import DepositIntentService, OfficialFundingConfig
    from app.modules.wallet.funding_models import DepositIntent
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = [datetime(2026, 9, 7, tzinfo=timezone.utc)]
    source, official = [address_from_public_key(PrivateKey().public_key.format(compressed=False)) for _ in range(2)]
    with factory.begin() as s:
        s.add(WalletControl(id='global', withdrawals_paused=True))
        s.add(WalletAddressOwner(address=source, user_id='alice', created_at=now[0]))
        s.flush()
        s.add(WalletBinding(id='binding', user_id='alice', address=source, version=1, status='ACTIVE',
            created_at=now[0], activated_at=now[0], effective_from_block=101, barrier_height=100,
            barrier_block_id='a' * 64, barrier_source_ids=['test-source'], barrier_observed_at=now[0]))
        s.add(WalletBindingState(user_id='alice', version=1, active_binding_id='binding'))
    service = DepositIntentService(factory, official_config=OfficialFundingConfig(address=official, version='test-v1'),
        intent_ttl=timedelta(minutes=20), clock=lambda: now[0])
    yield service, factory, now, source, official, DepositIntent
    engine.dispose()


def create(core, **overrides):
    args = dict(user_id='alice', expected_amount='10.000000', expected_binding_version=1, idempotency_key='first')
    args.update(overrides)
    return core[0].create(**args)


def test_snapshot_replay_and_conflict(core):
    first = create(core)
    assert first['source_address'] == core[3]
    assert first['official_address'] == core[4]
    assert first['binding_effective_from_block'] == 101
    assert first['created_at'] == core[2][0].isoformat()
    assert first['rules_snapshot']['minimum_amount'] == '10.000000'
    assert create(core) == first
    with pytest.raises(AppError, match='WALLET_IDEMPOTENCY_CONFLICT'):
        create(core, expected_amount='11.000000')
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_OPEN'):
        create(core, idempotency_key='second')


@pytest.mark.parametrize('amount', ['9.999999', '10', '10.0', '10.0000001', 'NaN', '1e1', 10.0, '-10.000000'])
def test_amount_rejected(core, amount):
    with pytest.raises(AppError, match='WALLET_DEPOSIT_AMOUNT_INVALID'):
        create(core, expected_amount=amount)


def test_expiry_releases_slot_and_status_is_scoped(core):
    first = create(core)
    core[2][0] += timedelta(minutes=20)
    assert core[0].status(user_id='alice', intent_id=first['id'])['status'] == 'EXPIRED'
    second = create(core, idempotency_key='second')
    assert second['id'] != first['id']
    with pytest.raises(AppError, match='WALLET_DEPOSIT_INTENT_NOT_FOUND'):
        core[0].status(user_id='bob', intent_id=first['id'])


@pytest.mark.parametrize('gate', ['pending', 'restricted', 'unbound', 'version', 'config'])
def test_gates(core, gate):
    with core[1].begin() as s:
        state = s.get(WalletBindingState, 'alice')
        if gate == 'pending':
            state.pending_binding_id = 'pending'
        elif gate == 'restricted':
            s.add(WalletSafetyState(id='alice', restricted=True, epoch=1, reason='TEST'))
        elif gate == 'unbound':
            state.active_binding_id = None
        elif gate == 'version':
            state.version = 2
    if gate == 'config':
        core[0].official_config = None
    with pytest.raises(AppError):
        create(core)


def test_rebind_closure_is_atomic_and_preserves_snapshot(core):
    first = create(core)
    with pytest.raises(RuntimeError):
        with core[1].begin() as s:
            core[0].close_by_rebind(s, user_id='alice', binding_id='binding', binding_version=1, actor_id='alice')
            raise RuntimeError('activation rollback')
    assert core[0].status(user_id='alice', intent_id=first['id'])['status'] == 'OPEN'
    with core[1].begin() as s:
        assert core[0].close_by_rebind(s, user_id='alice', binding_id='binding', binding_version=1, actor_id='alice') == 1
        assert core[0].close_by_rebind(s, user_id='alice', binding_id='binding', binding_version=1, actor_id='alice') == 0
    closed = core[0].status(user_id='alice', intent_id=first['id'])
    assert closed['status'] == 'CLOSED_BY_REBIND'
    for key in first.keys() - {'status', 'closed_at'}:
        assert closed[key] == first[key]


def test_audit_failure_rolls_back_create(core, monkeypatch):
    from app.modules.wallet import funding
    def fail(*args):
        raise RuntimeError('audit unavailable')
    monkeypatch.setattr(funding, 'audit_write', fail)
    with pytest.raises(RuntimeError, match='audit unavailable'):
        create(core)
    with core[1]() as s:
        assert s.scalar(select(core[5])) is None


@pytest.mark.parametrize('field,value', [('expected_amount', 11), ('source_address', 'changed'), ('binding_version', 2)])
def test_snapshot_orm_update_rejected(core, field, value):
    first = create(core)
    with pytest.raises(ValueError, match='immutable deposit intent'):
        with core[1].begin() as s:
            setattr(s.get(core[5], first['id']), field, value)


def test_closed_intent_cannot_reopen_or_delete(core):
    first = create(core)
    with core[1].begin() as s:
        core[0].close_by_rebind(s, user_id='alice', binding_id='binding', binding_version=1, actor_id='alice')
    with pytest.raises(ValueError, match='immutable deposit intent'):
        with core[1].begin() as s:
            row = s.get(core[5], first['id'])
            row.status, row.closed_at = 'OPEN', None
    with pytest.raises(ValueError, match='immutable deposit intent'):
        with core[1].begin() as s:
            s.delete(s.get(core[5], first['id']))


def test_database_open_slot_unique(core):
    from sqlalchemy.exc import IntegrityError
    first = create(core)
    with pytest.raises(IntegrityError):
        with core[1].begin() as s:
            row = s.get(core[5], first['id'])
            data = {col.name: getattr(row, col.name) for col in row.__table__.columns}
            data.update(id='duplicate', idempotency_key='duplicate')
            s.add(core[5](**data))


def test_changed_binding_payload_conflicts_and_exact_minimum_plus_unit(core):
    create(core, expected_amount='10.000001')
    with pytest.raises(AppError, match='WALLET_IDEMPOTENCY_CONFLICT'):
        create(core, expected_amount='10.000001', expected_binding_version=2)


def test_config_switch_replay_preserves_original_rules(core):
    from app.modules.wallet.funding import OfficialFundingConfig
    first = create(core)
    core[0].official_config = OfficialFundingConfig(address=core[4], version='test-v2')
    core[0].intent_ttl = timedelta(minutes=40)
    assert create(core) == first
    first['rules_snapshot']['minimum_amount'] = '1.000000'
    assert create(core)['rules_snapshot']['minimum_amount'] == '10.000000'


def test_expiry_audit_failure_rolls_back_status(core, monkeypatch):
    from app.modules.wallet import funding
    first = create(core)
    core[2][0] += timedelta(minutes=20)
    def fail(*args):
        raise RuntimeError('audit unavailable')
    monkeypatch.setattr(funding, 'audit_write', fail)
    with pytest.raises(RuntimeError, match='audit unavailable'):
        core[0].status(user_id='alice', intent_id=first['id'])
    with core[1]() as s:
        assert s.get(core[5], first['id']).status == 'OPEN'


def test_each_write_has_audit_and_outbox_but_replay_has_none(core):
    from app.core.outbox import OutboxEvent
    from app.modules.audit.models import AuditEvent
    first = create(core)
    create(core)
    core[2][0] += timedelta(minutes=20)
    core[0].status(user_id='alice', intent_id=first['id'])
    core[0].status(user_id='alice', intent_id=first['id'])
    with core[1]() as s:
        assert len(s.scalars(select(AuditEvent)).all()) == 2
        assert len(s.scalars(select(OutboxEvent)).all()) == 2
