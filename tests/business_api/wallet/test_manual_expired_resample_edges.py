"""Independent financial gates and races around bounded reserve resampling."""

from datetime import timedelta
from decimal import Decimal

import pytest
from sqlalchemy import func, select

from app.integrations.tron.funding_source import ReserveCutSample
from app.modules.ledger.manual_reserve_models import ManualReserveEvaluation
from app.modules.ledger.reserve import RedeemabilityReserve, require_coverage
from app.modules.wallet.models import WalletControl
from test_manual_expired_resample import setup_wait, expire
from test_manual_reserve_monitor import (
    core as core,
    coverage as coverage,
    monitor as monitor,
    digest_cut,
)


def _refresh_after_sleep(
    service, source, fresh, *, observation_id=2, before_refresh=None
):
    original = service.resample_sleep

    def refresh(delay):
        original(delay)
        if before_refresh:
            before_refresh()
        source.value = digest_cut(fresh, observation_id=observation_id)
        source.sample_only_age = False

    service.resample_sleep = refresh


def _evaluation_count(core):
    with core[1]() as session:
        return session.scalar(select(func.count()).select_from(ManualReserveEvaluation))


def test_fresh_same_observation_is_not_a_replacement(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor, budget=3)
    fresh = expire(source, clock)
    before = _evaluation_count(core)
    _refresh_after_sleep(service, source, fresh, observation_id=fresh.observation_id)
    result = service.run_once()
    assert result["complete"] is False
    assert result["codes"] == ["MANUAL_SOURCE_UNHEALTHY"]
    assert _evaluation_count(core) == before


def test_concurrent_reserve_version_change_during_wait_forces_retry(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    fresh = expire(source, clock)
    before = _evaluation_count(core)

    def mutate():
        with core[1].begin() as session:
            session.get(RedeemabilityReserve, "global").version += 1

    _refresh_after_sleep(service, source, fresh, before_refresh=mutate)
    result = service.run_once()
    assert result["status"] == "RETRY"
    assert result["codes"] == ["MANUAL_RESERVE_CHANGED"]
    assert _evaluation_count(core) == before


def test_replacement_expiring_at_final_commit_rolls_back_publication(
    core, monitor, monkeypatch
):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    fresh = expire(source, clock)
    before = _evaluation_count(core)
    _refresh_after_sleep(service, source, fresh)
    original = service._heartbeat
    expired = []

    def expire_after_publication(session, now, code=None):
        original(session, now, code)
        if code is None:
            clock[0] += timedelta(seconds=121)
            expired.append(True)

    monkeypatch.setattr(service, "_heartbeat", expire_after_publication)
    assert service.run_once()["complete"] is False
    assert expired == [True]
    assert _evaluation_count(core) == before
    with core[1]() as session:
        assert session.get(RedeemabilityReserve, "global").observed_at.year == 1970
        assert session.get(WalletControl, "global").withdrawals_paused


def test_changed_confirmation_read_retries_without_publication(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    fresh = expire(source, clock)
    before = _evaluation_count(core)
    _refresh_after_sleep(service, source, fresh)
    fresh_reads = []

    def changing_sample(**kwargs):
        if source.value.healthy:
            fresh_reads.append(True)
            if len(fresh_reads) > 1:
                return ReserveCutSample(
                    digest_cut(source.value, observation_id=3), False
                )
        return ReserveCutSample(source.value, source.sample_only_age)

    source.read_reserve_sample = changing_sample
    result = service.run_once()
    assert result["status"] == "RETRY"
    assert result["codes"] == ["MANUAL_SOURCE_CHANGED"]
    assert len(fresh_reads) == 2
    assert _evaluation_count(core) == before


def test_existing_pause_survives_wait_and_healthy_replacement(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    with core[1].begin() as session:
        session.get(WalletControl, "global").withdrawals_paused = True
    fresh = expire(source, clock)
    before = _evaluation_count(core)
    _refresh_after_sleep(service, source, fresh)
    result = service.run_once()
    assert result["complete"] is False
    assert result["codes"] == ["MANUAL_WALLET_PAUSED"]
    assert _evaluation_count(core) == before
    with core[1]() as session:
        assert session.get(WalletControl, "global").withdrawals_paused


def test_real_coverage_gate_rejects_invalidated_reserve_during_wait(core, monitor):
    service, source, clock, elapsed, sleeps = setup_wait(monitor)
    fresh = expire(source, clock)
    checked = []

    def check_gate():
        with core[1]() as session:
            reserve = session.get(RedeemabilityReserve, "global")
            assert reserve.observed_at.year == 1970
            with pytest.raises(ValueError, match="reserve evidence stale"):
                require_coverage(
                    session, reserve, usdt_delta=Decimal("1"), policy="manual_liquidity"
                )
            checked.append(True)

    _refresh_after_sleep(service, source, fresh, before_refresh=check_gate)
    assert service.run_once()["complete"] is True
    assert checked == [True]
