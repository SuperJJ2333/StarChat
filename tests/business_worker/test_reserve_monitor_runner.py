from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from importlib import import_module
from pathlib import Path
import sys
from threading import Event, Lock
from time import monotonic, sleep
from types import SimpleNamespace

import pytest


WORKER_APP = Path(__file__).parents[2] / "services" / "business-worker" / "app"
sys.path.insert(0, str(WORKER_APP))
WAITING = {"complete": False, "status": "WAITING", "codes": ["MANUAL_SOURCE_WAITING"]}


def runner_type():
    assert (WORKER_APP / "tasks" / "reserve_monitor_runner.py").exists(), (
        "The background reserve monitor runner is not implemented"
    )
    return import_module("tasks.reserve_monitor_runner").ReserveMonitorRunner


class BlockingMonitor:
    def __init__(self):
        self.started = Event()
        self.release = Event()
        self.finished = Event()
        self.lock = Lock()
        self.calls = 0
        self.active = 0
        self.max_active = 0
        self.failure = None

    def run_once(self):
        with self.lock:
            self.calls += 1
            call = self.calls
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        self.started.set()
        try:
            assert self.release.wait(5), "test did not release the monitor"
            if self.failure is not None:
                raise self.failure
            return {"complete": True, "status": "HEALTHY", "scan": call}
        finally:
            with self.lock:
                self.active -= 1
            self.finished.set()


def consume(runner):
    deadline = monotonic() + 2
    while monotonic() < deadline:
        result = runner.run_once()
        if result != WAITING:
            return result
        sleep(0.001)
    pytest.fail("completed scan was not delivered")


def test_blocked_monitor_leaves_caller_free_for_outbox_work():
    monitor = BlockingMonitor()
    runner = runner_type()(monitor)
    outbox_work = []

    class Consumer:
        def claim_batch(self, **_kwargs):
            return [SimpleNamespace(id="event-1", topic="wallet.alert")]

        def mark_succeeded(self, event_id, **_kwargs):
            outbox_work.append(event_id)

    worker = import_module("worker").Worker(
        consumer=Consumer(),
        handlers={"wallet.alert": lambda message: outbox_work.append("delivered")},
        worker_id="runner-test",
        maintenance_tasks=[runner.run_once, runner.ensure_running],
    )
    try:
        start = monotonic()
        assert worker.run_once() == 1
        assert monotonic() - start < 0.5
        assert monitor.started.wait(1)
        assert outbox_work == ["delivered", "event-1"]
        assert not monitor.finished.is_set()
    finally:
        monitor.release.set()
        runner.close()


def test_concurrent_entry_points_share_one_inflight_scan():
    monitor = BlockingMonitor()
    runner = runner_type()(monitor)
    try:
        with ThreadPoolExecutor(max_workers=8) as callers:
            calls = [runner.run_once, runner.ensure_running] * 20
            assert list(callers.map(lambda call: call(), calls)) == [WAITING] * 40
        assert monitor.started.wait(1)
        assert monitor.calls == 1
        assert monitor.max_active == 1
    finally:
        monitor.release.set()
        runner.close()


def test_auxiliary_schedule_preserves_result_for_exactly_one_consumption():
    monitor = BlockingMonitor()
    runner = runner_type()(monitor)
    try:
        assert runner.ensure_running() == WAITING
        assert monitor.started.wait(1)
        monitor.release.set()
        assert monitor.finished.wait(1)
        for _ in range(20):
            assert runner.ensure_running() == WAITING
        assert consume(runner) == {"complete": True, "status": "HEALTHY", "scan": 1}
        assert monitor.calls == 1
        assert runner.run_once() == WAITING
        assert consume(runner) == {"complete": True, "status": "HEALTHY", "scan": 2}
    finally:
        monitor.release.set()
        runner.close()


def test_failed_result_is_delivered_once_then_a_new_scan_can_start(caplog):
    monitor = BlockingMonitor()
    monitor.failure = ValueError("secret-provider-detail")
    runner = runner_type()(monitor)
    try:
        assert runner.ensure_running() == WAITING
        monitor.release.set()
        assert monitor.finished.wait(1)
        assert runner.ensure_running() == WAITING
        with pytest.raises(ValueError, match="secret-provider-detail"):
            consume(runner)
        assert "secret-provider-detail" not in caplog.text
        monitor.failure = None
        assert runner.run_once() == WAITING
        assert consume(runner)["scan"] == 2
    finally:
        monitor.release.set()
        runner.close()


def test_close_joins_before_dependencies_close_and_rejects_new_scans():
    monitor = BlockingMonitor()
    runner = runner_type()(monitor)
    closing = Event()
    closed = Event()
    order = []

    def close_resources():
        with ExitStack() as stack:
            stack.callback(lambda: order.append("dependencies-closed"))
            stack.callback(runner.close)
            closing.set()
        closed.set()

    try:
        runner.run_once()
        assert monitor.started.wait(1)
        with ThreadPoolExecutor(max_workers=1) as closer:
            future = closer.submit(close_resources)
            try:
                assert closing.wait(1)
                assert not closed.wait(0.05)
                assert order == []
            finally:
                monitor.release.set()
            future.result(timeout=2)
        assert monitor.finished.is_set()
        assert order == ["dependencies-closed"]
        runner.close()
        for call in (runner.run_once, runner.ensure_running):
            with pytest.raises(RuntimeError, match="closed"):
                call()
        assert monitor.calls == 1
    finally:
        monitor.release.set()
        runner.close()
