from importlib import util
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from pydantic import ValidationError

from app.core.config import Settings


ROOT = Path(__file__).parents[2]
sys.path.insert(0, str(ROOT / "services/business-worker/app"))


def test_budget_defaults_to_sixty_and_environment_can_disable(monkeypatch):
    monkeypatch.delenv(
        "BUSINESS_WALLET_MANUAL_STALE_RESAMPLE_BUDGET_SECONDS", raising=False
    )
    assert Settings(_env_file=None).wallet_manual_stale_resample_budget_seconds == 60
    monkeypatch.setenv("BUSINESS_WALLET_MANUAL_STALE_RESAMPLE_BUDGET_SECONDS", "0")
    assert Settings(_env_file=None).wallet_manual_stale_resample_budget_seconds == 0


@pytest.mark.parametrize("budget", [-1, 61, True, False, 1.5, "1.5", "invalid"])
def test_invalid_budget_is_rejected(budget):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, wallet_manual_stale_resample_budget_seconds=budget)


@pytest.fixture
def build_dependencies(monkeypatch):
    spec = util.spec_from_file_location(
        "reserve_runner_worker_main", ROOT / "services/business-worker/app/main.py"
    )
    module = util.module_from_spec(spec)
    spec.loader.exec_module(module)
    runtime = MagicMock()
    monitor = MagicMock()
    for path, name, implementation in [
        (
            "app.modules.wallet.runtime",
            "create_manual_wallet_runtime",
            MagicMock(return_value=runtime),
        ),
        ("app.integrations.tron.funding_source", "SQLiteFundingSource", MagicMock()),
        ("app.modules.wallet.funding_scan", "FundingScanService", MagicMock()),
        ("app.modules.wallet.funding_coverage", "FundingCoverageService", MagicMock()),
        ("app.modules.wallet.manual_reserve_monitor", "ManualReserveMonitor", monitor),
    ]:
        monkeypatch.setitem(
            sys.modules, path, SimpleNamespace(**{name: implementation})
        )
    settings = SimpleNamespace(
        wallet_real_mode="manual_tron",
        environment="test",
        tron_observer_database_path="isolated-observer.sqlite",
        wallet_official_address=MagicMock(),
        wallet_official_config_version="fixture-v1",
        wallet_funding_baseline_at=object(),
        wallet_funding_baseline_height=100,
        wallet_manual_stale_resample_budget_seconds=60,
        wallet_handover_preparation_mode=False,
    )
    return module, settings, runtime, monitor


@pytest.mark.parametrize(
    "budget,preparing,background",
    [(60, False, True), (1, False, True), (0, False, False), (60, True, False)],
)
def test_worker_shares_runner_and_keeps_zero_and_preparation_synchronous(
    build_dependencies, budget, preparing, background
):
    from tasks.reserve_monitor_runner import ReserveMonitorRunner

    module, settings, runtime, constructor = build_dependencies
    settings.wallet_manual_stale_resample_budget_seconds = budget
    settings.wallet_handover_preparation_mode = preparing
    maintenance, secondary, _ = module.build_wallet_tasks(settings, object())
    task = maintenance.__self__
    try:
        assert constructor.call_args.kwargs["stale_resample_budget_seconds"] == budget
        if background:
            assert isinstance(task.monitor, ReserveMonitorRunner)
            assert secondary == task.monitor.ensure_running
            assert task.monitor_runner is task.monitor
        else:
            assert task.monitor is constructor.return_value
            assert secondary == (
                task.monitor.preparation_once if preparing else task.monitor.run_once
            )
            assert task.monitor_runner is None
    finally:
        task.close()
    runtime.close.assert_called_once()


@pytest.mark.parametrize("close_fails", [False, True])
def test_manual_task_closes_runner_before_runtime_even_on_error(close_fails):
    from tasks.manual_wallet import ManualWalletMaintenanceTask

    order = []

    def close_runner():
        order.append("runner")
        if close_fails:
            raise RuntimeError("join failed")

    task = ManualWalletMaintenanceTask(
        object(),
        runtime=SimpleNamespace(close=lambda: order.append("runtime")),
        scanner=object(),
        monitor_runner=SimpleNamespace(close=close_runner),
    )
    if close_fails:
        with pytest.raises(RuntimeError, match="join failed"):
            task.close()
    else:
        task.close()
    assert order == ["runner", "runtime"]


def test_construction_failure_closes_runner_before_runtime(
    build_dependencies, monkeypatch
):
    module, settings, runtime, _ = build_dependencies
    order = []
    runner = MagicMock()
    runner.close.side_effect = lambda: order.append("runner")
    runtime.close.side_effect = lambda: order.append("runtime")
    monkeypatch.setitem(
        sys.modules,
        "tasks.reserve_monitor_runner",
        SimpleNamespace(ReserveMonitorRunner=MagicMock(return_value=runner)),
    )
    monkeypatch.setitem(
        sys.modules,
        "tasks.manual_wallet",
        SimpleNamespace(
            ManualWalletMaintenanceTask=MagicMock(
                side_effect=RuntimeError("construction failed")
            )
        ),
    )
    with pytest.raises(RuntimeError, match="construction failed"):
        module.build_wallet_tasks(settings, object())
    assert order == ["runner", "runtime"]


def test_manual_maintenance_uses_completed_scan_for_one_credit_cycle(monkeypatch):
    from threading import Event
    from time import monotonic, sleep

    from app.modules.wallet.receipt_models import DepositReceipt
    from tasks.manual_wallet import ManualWalletMaintenanceTask
    from tasks.reserve_monitor_runner import ReserveMonitorRunner

    release = Event()
    credits = []

    def scan():
        assert release.wait(3)
        return {"complete": True, "status": "PUBLISHED"}

    runner = ReserveMonitorRunner(SimpleNamespace(run_once=scan))
    runtime = SimpleNamespace(
        funds_enabled=True,
        close=lambda: None,
        receipts=SimpleNamespace(
            retry_credit=lambda identifier, **kwargs: (
                credits.append(identifier) or {"status": "CREDITED"}
            )
        ),
    )
    task = ManualWalletMaintenanceTask(
        object(),
        runtime=runtime,
        scanner=SimpleNamespace(run_once=lambda **kwargs: {"status": "OK"}),
        monitor=runner,
        monitor_runner=runner,
    )
    monkeypatch.setattr(
        task,
        "_page",
        lambda model, condition, after: (
            ["receipt"] if model is DepositReceipt else [],
            None,
        ),
    )
    try:
        assert task.run_once()["receipts_credited"] == 0
        release.set()
        for _ in range(20):
            runner.ensure_running()
        deadline = monotonic() + 2
        while not credits and monotonic() < deadline:
            task.run_once()
            sleep(0.001)
        assert credits == ["receipt"]
        release.clear()
        assert task.run_once()["receipts_credited"] == 0
        assert credits == ["receipt"]
    finally:
        release.set()
        task.close()


def test_compose_exposes_budget_only_to_worker():
    import yaml

    document = yaml.safe_load(
        (ROOT / "infra/compose/docker-compose.wallet-manual.yml").read_text(
            encoding="utf-8"
        )
    )
    variable = "BUSINESS_WALLET_MANUAL_STALE_RESAMPLE_BUDGET_SECONDS"
    assert variable not in document["services"]["business-api"]["environment"]
    assert (
        document["services"]["business-worker"]["environment"][variable]
        == "${" + variable + ":-60}"
    )
