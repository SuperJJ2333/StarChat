"""Keep bounded reserve scans off the worker's maintenance/Outbox thread."""

from concurrent.futures import Future, ThreadPoolExecutor
from threading import Lock
from typing import Any, Protocol


class ReserveMonitor(Protocol):
    def run_once(self) -> dict[str, Any]: ...


class ReserveMonitorRunner:
    """Share one scan and retain its result for the manual maintenance consumer."""

    def __init__(self, monitor: ReserveMonitor) -> None:
        self._monitor = monitor
        self._executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="reserve-monitor"
        )
        self._lock = Lock()
        self._future: Future[dict[str, Any]] | None = None
        self._closed = False

    def run_once(self) -> dict[str, Any]:
        """Consume a completed scan once, or schedule work without waiting for it."""
        with self._lock:
            self._check_open()
            if self._future is not None and self._future.done():
                completed = self._future
                self._future = None
                # Clear first so a failed scan can be retried. Only this method
                # delivers results/errors to the manual maintenance task.
                return completed.result()
            return self._ensure_running()

    def ensure_running(self) -> dict[str, Any]:
        """Schedule if idle; never consume or replace a completed scan."""
        with self._lock:
            self._check_open()
            return self._ensure_running()

    def _ensure_running(self) -> dict[str, Any]:
        if self._future is None:
            self._future = self._executor.submit(self._monitor.run_once)
        return {
            "complete": False,
            "status": "WAITING",
            "codes": ["MANUAL_SOURCE_WAITING"],
        }

    def _check_open(self) -> None:
        if self._closed:
            raise RuntimeError("reserve monitor runner is closed")

    def close(self) -> None:
        """Reject new scans and join the running scan before dependencies close."""
        with self._lock:
            self._closed = True
        # Do not hold the state lock while joining. Concurrent callers can fail
        # promptly, and every close caller waits for shutdown to finish.
        self._executor.shutdown(wait=True)
