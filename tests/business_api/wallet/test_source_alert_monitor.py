from datetime import timedelta
from sqlalchemy import select, func

from app.core.outbox import OutboxEvent
from app.integrations.tron.funding_source import FundingSourcePending, ReserveCutSample
from app.modules.wallet.models import WalletControl
from app.modules.ledger.reserve import RedeemabilityReserve
from test_manual_reserve_monitor import core, coverage, monitor, digest_cut  # noqa: F401


def test_pending_alert_waits_ten_minutes_without_publishing_or_pausing(core, monitor):
    service, source, clock = monitor
    since = int(clock[0].timestamp() * 1000)
    def pending():
        raise FundingSourcePending(since, int(clock[0].timestamp() * 1000) + 120000)
    source.read_reserve_cut = pending
    assert service.run_once()['complete'] is False
    clock[0] += timedelta(seconds=599)
    service.run_once()
    with core[1]() as session:
        assert session.scalar(select(func.count()).select_from(OutboxEvent)
            .where(OutboxEvent.topic == 'wallet.alert')) == 0
        assert not session.get(WalletControl, 'global').withdrawals_paused
        assert session.get(RedeemabilityReserve, 'global').observed_at.year == 1970
    clock[0] += timedelta(seconds=1)
    service.run_once()
    with core[1]() as session:
        alert = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert alert.payload['severity'] == 'P1'
        assert alert.event_headers['wallet_diagnostics']['duration_seconds'] == 600
        assert 'RECONCILIATION_PENDING' in alert.event_headers['wallet_diagnostics']['failed_conditions']


def test_failed_baseline_never_hidden_by_transient_sample(core, monitor):
    service, source, clock = monitor
    cut = digest_cut(source.value, healthy=False, solid_block=1,
                     fresh_until_ms=int(clock[0].timestamp()*1000)-1)
    source.read_reserve_sample = lambda: ReserveCutSample(cut, True, ('OBSERVATION_STALE',))
    assert service.run_once()['complete'] is False
    with core[1]() as session:
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert event is not None
        assert 'BASELINE_NOT_REACHED' in event.event_headers['wallet_diagnostics']['failed_conditions']


def test_p0_interruption_requires_three_new_healthy_observations(core, monitor):
    from app.modules.wallet.incident_models import WalletIncident
    service, _, clock = monitor
    with core[1].begin() as session:
        service._block(session, 'MANUAL_SOURCE_UNHEALTHY', clock[0])
    def healthy(observation):
        with core[1].begin() as session:
            service.incidents.source_healthy_in_session(session, observation, actor_id='fixture')
            service.incidents.observe_in_session(session, [], complete=True, clear_prefix='manual-reserve:')
    healthy(2)
    healthy(3)
    service._failed_source('MANUAL_SOURCE_UNAVAILABLE')
    healthy(4)
    with core[1]() as session:
        row = session.scalar(select(WalletIncident).where(WalletIncident.code == 'MANUAL_SOURCE_UNHEALTHY'))
        assert row.condition_active
    healthy(5)
    healthy(6)
    with core[1]() as session:
        assert not session.scalar(select(WalletIncident).where(
            WalletIncident.code == 'MANUAL_SOURCE_UNHEALTHY')).condition_active
