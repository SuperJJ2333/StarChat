"""Reserve restrictions and their alerts must commit or roll back together."""
import pytest
from concurrent.futures import ThreadPoolExecutor
from sqlalchemy import create_engine, select, func

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.models import WalletControl
from app.modules.wallet import funding_models, binding_models  # noqa: F401
from test_wallet_incidents import factory, service, SIGNAL, SOURCE_TIMEOUT  # noqa: F401


def test_incident_can_join_existing_financial_transaction(factory):
    WalletControl.__table__.create(factory.kw['bind'], checkfirst=True)
    with factory.begin() as session:
        session.add(WalletControl(id='global', withdrawals_paused=True))
        session.flush()
        result = service(factory).observe_in_session(session, [SIGNAL], complete=False)
        assert result[0]['code'] == SIGNAL['code']
    with factory() as session:
        assert session.get(WalletControl, 'global').withdrawals_paused
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 1
        assert session.scalar(select(func.count()).select_from(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')) == 1


def test_caller_failure_rolls_back_pause_and_incident_alert(factory):
    WalletControl.__table__.create(factory.kw['bind'], checkfirst=True)
    with pytest.raises(RuntimeError, match='caller failure'):
        with factory.begin() as session:
            session.add(WalletControl(id='global', withdrawals_paused=True))
            session.flush()
            service(factory).observe_in_session(session, [SIGNAL], complete=False)
            raise RuntimeError('caller failure')
    with factory() as session:
        assert session.get(WalletControl, 'global') is None
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 0
        assert session.scalar(select(func.count()).select_from(OutboxEvent)) == 0


def test_partial_transaction_observation_never_clears_other_monitor(factory):
    old = service(factory).observe([SIGNAL])[0]
    with factory.begin() as session:
        service(factory).observe_in_session(session, [], complete=False)
    assert service(factory).get(old['id'])['condition_active']


@pytest.mark.parametrize('keys', [('race-one', 'race-two'), ('race-one', 'race-one')])
def test_historical_correction_race_changes_only_once(tmp_path, keys):
    engine = create_engine('sqlite+pysqlite:///' + str(tmp_path / 'incident-race.db'),
        connect_args={'check_same_thread': False, 'timeout': 10})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    row = service(factory).observe([dict(SOURCE_TIMEOUT, severity='P0')])[0]
    def correct(key):
        try:
            return service(factory).reclassify_source_timeout(row['id'], actor_id='operator',
                idempotency_key=key, generation=row['generation'], expected_version=row['version'],
                diagnostic_code='SOURCE_READ_BUDGET_EXPIRED', evidence_digest='f'*64)
        except AppError as error:
            return error.code
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(correct, keys))
        if keys[0] == keys[1]:
            assert all(isinstance(value, dict) and value == results[0] for value in results)
        else:
            assert sorted('T2' if isinstance(value, dict) else value for value in results) == [
                'T2', 'WALLET_INCIDENT_VERSION_CONFLICT']
        with factory() as session:
            assert session.scalar(select(func.count()).select_from(OutboxEvent).where(
                OutboxEvent.event_type == 'wallet.incident.source_timeout_reclassified')) == 1
    finally:
        engine.dispose()
