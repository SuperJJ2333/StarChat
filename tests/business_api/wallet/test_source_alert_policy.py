from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy import create_engine, select, func

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.modules.wallet.incidents import WalletIncidentService
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet import models, funding_models, binding_models  # noqa: F401


@pytest.fixture
def policy():
    engine = create_engine('sqlite://')
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    clock = [datetime(2026, 10, 5, tzinfo=timezone.utc)]
    service = WalletIncidentService(factory, now_factory=lambda: clock[0])
    yield service, factory, clock
    engine.dispose()


def failure(policy, conditions=('BALANCE_UNSTABLE', 'RECONCILIATION_PENDING'), observation=1):
    service, factory, _ = policy
    with factory.begin() as session:
        return service.source_failure_in_session(session,
            dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNHEALTHY',
                 code='MANUAL_SOURCE_UNHEALTHY', severity='P1', subject_id='global'),
            dict(failed_conditions=list(conditions), observation_id=observation),
            actor_id='manual-reserve-monitor')


def count_alerts(factory):
    with factory() as session:
        return session.scalar(select(func.count()).select_from(OutboxEvent)
            .where(OutboxEvent.topic == 'wallet.alert'))


def healthy(policy, observation):
    service, factory, _ = policy
    with factory.begin() as session:
        service.source_healthy_in_session(session, observation, actor_id='manual-reserve-monitor')
        service.observe_in_session(session, [], complete=True, clear_prefix='manual-reserve:')


def test_ten_minute_boundary_survives_service_restart_and_deduplicates(policy):
    service, factory, clock = policy
    assert failure(policy) is False
    clock[0] += timedelta(seconds=599)
    restarted = WalletIncidentService(factory, now_factory=lambda: clock[0])
    policy = restarted, factory, clock
    assert failure(policy, ('OBSERVATION_STALE',)) is False
    assert count_alerts(factory) == 0
    clock[0] += timedelta(seconds=1)
    assert failure(policy) is True
    assert failure(policy) is True
    assert count_alerts(factory) == 1
    with factory() as session:
        event = session.scalar(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))
        assert event.event_headers['wallet_diagnostics']['duration_seconds'] == 600
        assert event.event_headers['wallet_diagnostics']['failed_conditions'] == [
            'BALANCE_UNSTABLE', 'RECONCILIATION_PENDING']


def test_three_distinct_healthy_observations_prevent_flapping(policy):
    _, factory, clock = policy
    failure(policy)
    clock[0] += timedelta(seconds=600)
    failure(policy)
    healthy(policy, 2)
    healthy(policy, 2)  # repeated polling of one snapshot is not recovery
    healthy(policy, 3)
    with factory() as session:
        assert session.scalar(select(WalletIncident)).condition_active
    failure(policy, observation=3)
    healthy(policy, 4)
    healthy(policy, 5)
    with factory() as session:
        assert session.scalar(select(WalletIncident)).condition_active
    healthy(policy, 6)
    with factory() as session:
        assert not session.scalar(select(WalletIncident)).condition_active
    assert count_alerts(factory) == 1
    failure(policy, observation=6)
    clock[0] += timedelta(seconds=600)
    failure(policy, observation=7)
    assert count_alerts(factory) == 2


@pytest.mark.parametrize('conditions', [
    ['BALANCE_DISCREPANCY'], ['CLOCK_AHEAD'], ['BASELINE_NOT_REACHED'],
    ['UNKNOWN'], ['OBSERVATION_STALE', 'BALANCE_DISCREPANCY'], [],
])
def test_critical_or_unknown_cause_is_never_delayed(policy, conditions):
    assert failure(policy, conditions) is True
    assert count_alerts(policy[1]) == 1


def test_raw_sensitive_context_rejected(policy):
    service, factory, _ = policy
    with factory.begin() as session, pytest.raises(ValueError):
        service.source_failure_in_session(session,
            dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNHEALTHY',
                 code='MANUAL_SOURCE_UNHEALTHY', severity='P1', subject_id='global'),
            {'failed_conditions':['OBSERVATION_STALE'], 'secret':'must-not-persist'},
            actor_id='manual-reserve-monitor')
    assert count_alerts(factory) == 0


def test_new_critical_cause_notifies_even_during_existing_transient_incident(policy):
    _, factory, clock = policy
    failure(policy)
    clock[0] += timedelta(seconds=600)
    failure(policy)
    failure(policy, ['BALANCE_DISCREPANCY'])
    failure(policy, ['BALANCE_DISCREPANCY'])
    assert count_alerts(factory) == 2
    with factory() as session:
        alerts = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')
            .order_by(OutboxEvent.created_at, OutboxEvent.id)).all()
        assert {tuple(event.event_headers['wallet_diagnostics']['failed_conditions'])
                for event in alerts} == {('BALANCE_UNSTABLE', 'RECONCILIATION_PENDING'),
                                        ('BALANCE_DISCREPANCY',)}


def test_clock_rollback_notifies_new_critical_cause(policy):
    _, factory, clock = policy
    first = clock[0]
    failure(policy, ['OBSERVATION_STALE'])
    clock[0] += timedelta(seconds=600)
    failure(policy, ['OBSERVATION_STALE'])
    clock[0] = first - timedelta(seconds=1)
    failure(policy, ['OBSERVATION_STALE'])
    assert count_alerts(factory) == 2
    with factory() as session:
        contexts = [row.event_headers['wallet_diagnostics'] for row in
            session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert'))]
        assert ['CLOCK_AHEAD'] in [value['failed_conditions'] for value in contexts]


def test_first_and_latest_diagnosis_are_durable_before_notification(policy):
    from app.modules.wallet.incident_models import WalletSourceAlertState
    _, factory, _ = policy
    failure(policy, ['BALANCE_UNSTABLE'])
    failure(policy, ['OBSERVATION_STALE'])
    with factory() as session:
        state = session.get(WalletSourceAlertState, 'global')
        assert state.first_context['failed_conditions'] == ['BALANCE_UNSTABLE']
        assert state.latest_context['failed_conditions'] == ['OBSERVATION_STALE']
    assert count_alerts(factory) == 0


def test_new_escalation_copies_recorded_cause(policy):
    service, factory, clock = policy
    with factory.begin() as session:
        service.observe_in_session(session,
            [dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNAVAILABLE',
                  code='MANUAL_SOURCE_UNAVAILABLE', severity='P0', subject_id='global')],
            alert_context={'failed_conditions':['SOURCE_MALFORMED']})
    clock[0] += timedelta(seconds=301)
    service.escalate()
    with factory() as session:
        events = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')).all()
        assert len(events) == 2
        assert all(event.event_headers['wallet_diagnostics']['failed_conditions']
                   == ['SOURCE_MALFORMED'] for event in events)


def test_reopened_unknown_cause_never_inherits_previous_generation(policy):
    service, factory, clock = policy
    signal = dict(fingerprint='manual-reserve:MANUAL_SOURCE_UNAVAILABLE',
                  code='MANUAL_SOURCE_UNAVAILABLE', severity='P0', subject_id='global')
    with factory.begin() as session:
        service.observe_in_session(session, [signal],
            alert_context={'failed_conditions':['SOURCE_MALFORMED']})
    clock[0] += timedelta(seconds=1)
    service.observe([], complete=True)
    clock[0] += timedelta(seconds=1)
    service.observe([signal])
    with factory() as session:
        events = session.scalars(select(OutboxEvent).where(OutboxEvent.topic == 'wallet.alert')
            .order_by(OutboxEvent.created_at)).all()
        assert events[0].event_headers['wallet_diagnostics']['failed_conditions'] == ['SOURCE_MALFORMED']
        assert events[1].event_headers['wallet_diagnostics']['failed_conditions'] == ['UNKNOWN']
