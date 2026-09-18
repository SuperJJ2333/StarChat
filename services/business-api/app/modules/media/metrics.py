"""Media Platform metrics (Phase 4.1, requirement §12).

Records exactly the five required observations:

``media_resolve_ms`` / ``variant_resolve_ms`` / ``authorization_ms`` / ``cache_hit`` /
``storage_read_ms``

Hard privacy rule (requirement §12 and phase-3.1 invariant I8): labels never contain a
user id, room id, event id, token, key, digest, storage path or message content. The
counters are process-local and non-persistent; the debug line prints numbers only, so it
is safe to attach to a support ticket.

Counters always increment; only the timing probes are gated, so a non-profile build still
answers "was this a cache hit?".
"""

from __future__ import annotations

import json
import os
import time
from contextlib import contextmanager
from typing import Any, Iterator


def _enabled() -> bool:
    return os.environ.get("CHATFLOW_MEDIA_METRICS", "").strip().casefold() in {
        "1",
        "true",
        "yes",
    }


class MediaPlatformMetrics:
    """Process-local counters and latency samples for the media platform."""

    def __init__(self) -> None:
        self.reset()

    # -- lifecycle ---------------------------------------------------------
    def reset(self) -> None:
        self._counters: dict[str, int] = {
            "media_resolve": 0,
            "variant_resolve": 0,
            "authorization": 0,
            "cache_hit": 0,
            "cache_miss": 0,
            "object_created": 0,
            "object_reused": 0,
            "blob_written": 0,
            "blob_read": 0,
            "reference_attached": 0,
            "reference_released": 0,
            "grant_issued": 0,
            "grant_revoked": 0,
            "signed_url_issued": 0,
            "signed_url_rejected": 0,
            "authorization_denied": 0,
            "gc_run": 0,
            "gc_collected": 0,
            "gc_bytes_reclaimed": 0,
            "legacy_read_delegated": 0,
            "moments_bridge_attached": 0,
            "reconcile_rebuilt": 0,
            "reconcile_invalidated": 0,
            "ingest_digest_slot_race_reused": 0,
            "reference_attach_race_reused": 0,
            "grant_issue_race_reused": 0,
            "upload_session_created": 0,
            "upload_session_aborted": 0,
        }
        self._samples: dict[str, list[float]] = {
            "media_resolve_ms": [],
            "variant_resolve_ms": [],
            "authorization_ms": [],
            "storage_read_ms": [],
        }

    # -- recording ---------------------------------------------------------
    def increment(self, name: str, amount: int = 1) -> None:
        if name not in self._counters:
            raise KeyError(f"unknown media metric: {name}")
        self._counters[name] += amount

    def observe_ms(self, name: str, duration_ms: float) -> None:
        if name not in self._samples:
            raise KeyError(f"unknown media timing: {name}")
        if not _enabled():
            return
        samples = self._samples[name]
        samples.append(float(duration_ms))
        # Keep memory bounded: a rolling window is enough for diagnosis.
        if len(samples) > 512:
            del samples[: len(samples) - 512]

    @contextmanager
    def timed(self, name: str) -> Iterator[None]:
        started = time.perf_counter()
        try:
            yield
        finally:
            self.observe_ms(name, (time.perf_counter() - started) * 1000.0)

    # -- reading -----------------------------------------------------------
    def counter(self, name: str) -> int:
        return self._counters[name]

    def timing(self, name: str) -> dict[str, float | int]:
        samples = self._samples[name]
        if not samples:
            return {"count": 0, "avg_ms": 0.0, "max_ms": 0.0}
        return {
            "count": len(samples),
            "avg_ms": round(sum(samples) / len(samples), 3),
            "max_ms": round(max(samples), 3),
        }

    def snapshot(self) -> dict[str, Any]:
        return {
            "counters": dict(self._counters),
            "timings": {name: self.timing(name) for name in self._samples},
        }

    def debug_line(self) -> str:
        """Numbers only: no ids, no digests, no paths, no tokens."""

        payload = {
            "counters": self._counters,
            "timings": {name: self.timing(name)["avg_ms"] for name in self._samples},
            "timing_samples": {name: self.timing(name)["count"] for name in self._samples},
        }
        return "[chatflow/mediaplatform] " + json.dumps(payload, sort_keys=True)


#: Single process-local instance; the API and the worker each have their own.
media_platform_metrics = MediaPlatformMetrics()
