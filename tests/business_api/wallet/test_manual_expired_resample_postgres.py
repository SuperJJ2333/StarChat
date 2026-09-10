"""Isolated PostgreSQL proof of locks and CAS during bounded reserve waiting."""

from concurrent.futures import ThreadPoolExecutor
import os
from threading import Event
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, text

from app.core.database import create_session_factory
from app.integrations.tron.funding_source import ReserveCutSample
from app.modules.ledger.reserve import (
    RedeemabilityReserve,
    lock_budget,
    require_coverage,
)
from app.modules.ledger.wallet_obligations import synchronize_wallet_liability
from app.modules.wallet.manual_reserve_monitor import ManualReserveMonitor
from app.modules.wallet.models import WalletControl
from app.modules.wallet.monitoring import WalletMonitorHeartbeat
import test_deposit_receipts as receipt_fixtures
from test_manual_reserve_monitor import coverage, digest_cut, monitor  # noqa: F401


@pytest.fixture
def core(monkeypatch):
    url = os.getenv("REPORTING_PG_URL")
    if not url:
        pytest.skip("REPORTING_PG_URL is required for isolated PostgreSQL integration")
    schema = "reservewait_" + uuid4().hex
    admin = create_engine(url)
    with admin.begin() as connection:
        connection.execute(text(f"CREATE SCHEMA {schema}"))
    engine = create_engine(
        url,
        connect_args={"options": f"-csearch_path={schema}"},
        pool_size=1,
        max_overflow=0,
        pool_timeout=1,
    )
    monkeypatch.setattr(
        receipt_fixtures, "create_engine", lambda *args, **kwargs: engine
    )
    try:
        yield from receipt_fixtures.core.__wrapped__()
    finally:
        engine.dispose()
        with admin.begin() as connection:
            connection.execute(text(f"DROP SCHEMA {schema} CASCADE"))
        admin.dispose()


@pytest.mark.parametrize("concurrent_change", [False, True])
def test_postgres_wait_releases_financial_locks_retains_scan_lock_and_checks_version(
    core,
    monitor,  # noqa: F811
    concurrent_change,
):
    original, source, clock = monitor
    assert original.run_once()["complete"] is True
    fresh = source.value
    source.value = digest_cut(
        fresh, healthy=False, fresh_until_ms=int(clock[0].timestamp() * 1000) - 1
    )
    source.read_reserve_sample = lambda **kwargs: ReserveCutSample(
        source.value, not source.value.healthy
    )
    waiting, release = Event(), Event()

    def wait_for_test(_seconds):
        waiting.set()
        assert release.wait(10), "test failed to release waiting monitor"

    service = ManualReserveMonitor(
        core[1],
        source=source,
        official_config=original.config,
        activation_baseline_time=original.baseline,
        activation_baseline_height=original.baseline_height,
        clock=original.clock,
        stale_resample_budget_seconds=60,
        resample_sleep=wait_for_test,
    )
    engine = core[1].kw["bind"]
    # A genuinely separate pool shares the schema; neither source nor budget
    # work can use the waiting scan's connection accidentally.
    # Preserve the fixture's search_path, which is a connect_arg rather than URL option.
    with engine.connect() as connection:
        schema = connection.scalar(text("SELECT current_schema()"))
    other_engine = create_engine(
        engine.url,
        connect_args={"options": f"-csearch_path={schema}"},
        pool_size=1,
        max_overflow=0,
        pool_timeout=1,
    )
    other = create_session_factory(other_engine)
    competing = ManualReserveMonitor(
        other,
        source=source,
        official_config=original.config,
        activation_baseline_time=original.baseline,
        activation_baseline_height=original.baseline_height,
        clock=original.clock,
    )
    try:
        with ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(service.run_once)
            try:
                assert waiting.wait(5), "monitor did not reach bounded wait"
                assert competing.run_once()["codes"] == ["MONITOR_SCAN_BUSY"]
                with other.begin() as session:
                    session.execute(text("SET LOCAL lock_timeout = '500ms'"))
                    reserve = lock_budget(session)
                    assert reserve.observed_at.year == 1970
                    assert (
                        session.get(WalletControl, "global").withdrawals_paused is False
                    )
                    heartbeat = session.get(WalletMonitorHeartbeat, "global")
                    assert heartbeat is not None
                    assert heartbeat.last_error_code == "MANUAL_SOURCE_WAITING"
                    with pytest.raises(ValueError, match="reserve evidence stale"):
                        require_coverage(session, reserve)
                    if concurrent_change:
                        before = reserve.version
                        synchronize_wallet_liability(
                            session, total=reserve.usdt_liability + 1
                        )
                        assert reserve.version == before + 1
                    expected_version = reserve.version
                source.value = digest_cut(
                    fresh, observation_id=fresh.observation_id + 1
                )
            finally:
                release.set()
            result = pending.result(timeout=10)
        with other() as session:
            reserve = session.get(RedeemabilityReserve, "global")
            if concurrent_change:
                assert result == {
                    "complete": False,
                    "status": "RETRY",
                    "codes": ["MANUAL_RESERVE_CHANGED"],
                }
                assert reserve.version == expected_version
                assert reserve.observed_at.year == 1970
            else:
                assert result["complete"] is True
                assert result["status"] == "PUBLISHED"
                assert reserve.version > expected_version
                require_coverage(session, reserve)
    finally:
        release.set()
        other_engine.dispose()
