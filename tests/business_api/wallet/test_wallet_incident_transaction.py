"""Reserve restrictions and their alerts must commit or roll back together."""
import pytest
from sqlalchemy import select, func

from app.core.outbox import OutboxEvent
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.models import WalletControl
from app.modules.wallet import funding_models, binding_models  # noqa: F401
from test_wallet_incidents import factory, service, SIGNAL  # noqa: F401


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
