"""A stale cut is never consumed; bounded resampling preserves fund gates."""

from datetime import timedelta

import pytest
from sqlalchemy import func, select

from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.wallet.incident_models import WalletIncident
from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
from app.modules.wallet.models import WalletControl
from test_manual_reserve_monitor import (
    core as core,
    coverage as coverage,
    monitor as monitor,
    digest_cut,
)


def setup_wait(monitor, *, budget=5):
    original, source, clock = monitor
    elapsed = [0.0]
    sleeps = []

    def sleep(seconds):
        sleeps.append(seconds)
        elapsed[0] += seconds
        clock[0] += timedelta(seconds=seconds)

    service = ManualReserveMonitor(
        original.factory,
        source=source,
        official_config=original.config,
        activation_baseline_time=original.baseline,
        activation_baseline_height=original.baseline_height,
        clock=original.clock,
        stale_resample_budget_seconds=budget,
        resample_monotonic=lambda: elapsed[0],
        resample_sleep=sleep,
    )
    assert original.run_once()["complete"]
    from app.integrations.tron.funding_source import ReserveCutSample

    source.sample_only_age = True
    source.read_reserve_sample = lambda **kwargs: ReserveCutSample(
        source.value, source.sample_only_age
    )
    return service, source, clock, elapsed, sleeps


def expire(source, clock):
    fresh = source.value
    source.value = digest_cut(
        fresh, healthy=False, fresh_until_ms=int(clock[0].timestamp() * 1000) - 1
    )
    return fresh


def test_wait_recovers_with_new_observation_without_incident(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    fresh = expire(source, clock)
    old_sleep = service.resample_sleep

    def refresh(delay):
        old_sleep(delay)
        if elapsed[0] >= 2:
            source.value = digest_cut(fresh, observation_id=2)
            source.sample_only_age = False

    service.resample_sleep = refresh
    assert service.run_once()["complete"] is True
    assert elapsed[0] == 2
    with core[1]() as session:
        assert not session.get(WalletControl, "global").withdrawals_paused
        assert session.scalar(select(func.count()).select_from(WalletIncident)) == 0


def test_same_observation_never_refreshes_wait_deadline(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor, budget=3)
    expire(source, clock)
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert 0 < elapsed[0] <= 3 and max(sleeps) <= 1
    with core[1]() as session:
        assert session.get(WalletControl, "global").withdrawals_paused


def test_non_age_failure_does_not_wait(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    expire(source, clock)
    source.sample_only_age = False
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert sleeps == []


def test_invalid_digest_does_not_wait(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    from dataclasses import replace

    expire(source, clock)
    source.value = replace(source.value, digest="0" * 64)
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_INVALID"]
    assert sleeps == []


def test_wait_invalidates_reserve_before_sleep_and_preserves_version_check(
    core, monitor
):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    source.sample_only_age = False
    assert service.run_once()["complete"]
    fresh = expire(source, clock)
    source.sample_only_age = True
    old_sleep = service.resample_sleep

    def refresh(delay):
        with core[1]() as session:
            reserve = session.get(RedeemabilityReserve, "global")
            assert reserve.observed_at.year == 1970
            assert not session.get(WalletControl, "global").withdrawals_paused
        old_sleep(delay)
        source.value = digest_cut(fresh, observation_id=2)
        source.sample_only_age = False

    service.resample_sleep = refresh
    assert service.run_once()["complete"]


def test_new_source_fault_interrupts_wait(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    expire(source, clock)
    old_sleep = service.resample_sleep

    def fail(delay):
        old_sleep(delay)
        source.sample_only_age = False

    service.resample_sleep = fail
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert elapsed[0] == 1


def test_ancient_cut_does_not_receive_new_wait_after_restart(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor, budget=3)
    expire(source, clock)
    clock[0] += timedelta(seconds=4)
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert sleeps == []


def test_missing_reserve_cannot_enter_extended_wait(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    with core[1].begin() as session:
        session.delete(session.get(RedeemabilityReserve, "global"))
    expire(source, clock)
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert sleeps == []


@pytest.mark.parametrize("budget", [-1, 61, True, float("nan"), float("inf")])
def test_budget_configuration_is_bounded(monitor, budget):
    with pytest.raises(ValueError):
        setup_wait(monitor, budget=budget)


def test_confirmation_read_cannot_overrun_wait_budget(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor, budget=3)
    fresh = expire(source, clock)
    original_sleep = service.resample_sleep
    original_read = source.read_reserve_sample
    reads = []

    def refresh(delay):
        original_sleep(delay)
        source.value = digest_cut(fresh, observation_id=2)
        source.sample_only_age = False

    def read(*, timeout_seconds):
        reads.append(timeout_seconds)
        if len(reads) == 3:
            elapsed[0] += 3
            clock[0] += timedelta(seconds=3)
        return original_read(timeout_seconds=timeout_seconds)

    service.resample_sleep = refresh
    source.read_reserve_sample = read
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert len(reads) == 3
    assert all(0 < budget <= 1 for budget in reads)
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, "global").observed_at.year == 1970


def test_wall_clock_rollback_cannot_restart_monotonic_budget(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor, budget=3)
    expire(source, clock)
    original_sleep = service.resample_sleep

    def rollback(delay):
        original_sleep(delay)
        clock[0] -= timedelta(seconds=2)

    service.resample_sleep = rollback
    assert service.run_once()["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert 0 < elapsed[0] <= 3
