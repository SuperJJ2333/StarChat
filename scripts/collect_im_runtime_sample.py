"""Finite aggregate-only Docker sample. No raw log lines, identifiers or URLs.

Run on the Docker host; this diagnostic never installs a resident agent.
HTTP observations do not establish user recoveries or push device delivery.
"""

import argparse
import collections
import datetime as dt
import itertools
import json
import math
import queue
import re
import subprocess
import threading
import time
from dataclasses import dataclass
from urllib.parse import parse_qs, urlsplit

SERVICES = {
    "business_api": "starchat-business-api-1",
    "getui_bridge": "starchat-getui-bridge-1",
    "synapse": "starchat-synapse-1",
    "sync_worker": "starchat-synapse-sync-worker-1",
}
METHOD = r"(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS)"
REQUEST = re.compile(r'"(' + METHOD + r') ([^\s"]+)(?: HTTP/[0-9.]+)?"')
START = re.compile(r"Received request:\s*(" + METHOD + r') ([^\s"]+)')
HTTPX = re.compile(
    r"HTTP Request:\s*(" + METHOD + r') ([^\s"]+)\s+"HTTP/[0-9.]+ ([1-5][0-9]{2})\b'
)
REQUEST_ID = re.compile(r"\b(" + METHOD + r"-[0-9]+)\b")
INSPECT_FORMAT = (
    '{"image":{{json .Image}},"status":{{json .State.Status}},'
    '"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},'
    '"restart_count":{{.RestartCount}}}'
)
STATS_FORMAT = (
    '{"cpu":{{json .CPUPerc}},"memory":{{json .MemUsage}},'
    '"memory_percent":{{json .MemPerc}},"pids":{{json .PIDs}}}'
)


def route_category(target):
    try:
        path = urlsplit(target).path.rstrip("/") or "/"
    except ValueError:
        return "other"
    if path in {
        "/health",
        "/healthz",
        "/ready",
        "/readyz",
        "/api/health",
        "/api/v1/health",
    }:
        return "health"
    if re.fullmatch(r"/_matrix/client/(?:v3|r0|unstable)/sync", path):
        return "sync"
    if re.fullmatch(
        r"/(?:api/v1/)?auth/matrix-recovery-authorize", path
    ) or re.fullmatch(
        r"/(?:api/v1/)?direct-conversations/(?:publish-recovery|reserve-recovery)", path
    ):
        return "recovery_route"
    if re.match(
        r"/_matrix/media/|/_matrix/client/(?:v3|r0)/media/|/api/v1/(?:media|avatars?)(?:/|$)",
        path,
    ):
        return "media"
    if re.fullmatch(r"/v2/[^/]+/push/(?:single|list)/cid", path):
        return "provider_push_http"
    if path in {"/_matrix/push/v1/notify", "/push/v1/notify"}:
        return "push_gateway"
    return "other"


def _idle_sync(line, target, status, category):
    if status != "200" or category != "sync" or "[0 dbevts]" not in line:
        return False
    duration = re.search(r"Processed request:\s*([0-9]+(?:\.[0-9]+)?)sec", line)
    if not duration or float(duration.group(1)) < 29:
        return False
    try:
        return parse_qs(urlsplit(target).query).get("timeout") == ["30000"]
    except ValueError:
        return False


def summarize_logs(
    lines,
    *,
    tail_limit=10000,
    byte_truncated=False,
    partial_last_line=False,
    command_timeout=False,
):
    """Conserve observed lines and start/completion records, not user counts.

    Uncompleted starts can cross the sample window. Correlation IDs stay only
    in this bounded in-memory pass; no raw value is returned or persisted.
    """
    kinds = collections.Counter(
        dict.fromkeys(
            (
                "http_completed",
                "http_started",
                "http_without_completion_status",
                "traceback_header",
                "partial_line",
                "oversized_line",
                "unmatched",
            ),
            0,
        )
    )
    buckets, pending = collections.Counter(), collections.Counter()
    started = paired = unpaired_starts = idle = 0
    observed = list(itertools.islice(lines, tail_limit))
    for index, line in enumerate(observed):
        if partial_last_line and index == len(observed) - 1:
            kinds["partial_line"] += 1
            continue
        if len(line) > 16384:
            kinds["oversized_line"] += 1
            continue
        incoming, outgoing, opening = (
            REQUEST.search(line),
            HTTPX.search(line),
            START.search(line),
        )
        request_id = REQUEST_ID.search(line)
        identity = request_id.group(1) if request_id else None
        status = None
        if incoming:
            method, target = incoming.groups()
            after = re.match(r"\s+([1-5][0-9]{2})\b", line[incoming.end() :])
            before = re.search(r"\b([1-5][0-9]{2})\s+$", line[: incoming.start()])
            if after:
                status = after.group(1)
            elif before and "Processed request:" in line[: incoming.start()]:
                status = before.group(1)
        elif outgoing:
            method, target, status = outgoing.groups()
        elif opening:
            method, target = opening.groups()
        else:
            kinds[
                (
                    "traceback_header"
                    if "Traceback (most recent call last)" in line
                    else "unmatched"
                )
            ] += 1
            continue
        category = route_category(target)
        key = (identity, method, category)
        if status is not None:
            kinds["http_completed"] += 1
            buckets[f"{category}:{status}"] += 1
            if identity and pending[key]:
                pending[key] -= 1
                paired += 1
            idle += int(_idle_sync(line, target, status, category))
        elif opening:
            kinds["http_started"] += 1
            started += 1
            if identity:
                pending[key] += 1
            else:
                unpaired_starts += 1
        else:
            kinds["http_without_completion_status"] += 1
    completed = kinds["http_completed"]
    return {
        "log_lines": len(observed),
        "line_buckets": dict(kinds),
        "http_completed": completed,
        "http_buckets": dict(sorted(buckets.items())),
        "started_request_records": started,
        "completed_with_observed_start": paired,
        "completed_without_observed_start": completed - paired,
        "started_without_observed_completion": sum(pending.values()) + unpaired_starts,
        "uncorrelated_started_records": unpaired_starts,
        "http_without_completion_status": kinds["http_without_completion_status"],
        "idle_sync_30s_completed": idle,
        "traceback_headers": kinds["traceback_header"],
        "truncation": {
            "tail_limit": tail_limit,
            "tail_limit_reached": len(observed) >= tail_limit,
            "byte_limit_reached": byte_truncated,
            "command_timeout": command_timeout,
            "partial_last_line": partial_last_line,
        },
    }


@dataclass
class CommandResult:
    data: bytes
    error: str | None = None
    byte_limit_reached: bool = False


def run_bounded(argv, *, max_bytes, timeout):
    """Bound memory/time without storing raw output on disk or printing errors."""
    try:
        process = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
    except OSError:
        return CommandResult(b"", "unavailable")
    messages, stopped = queue.Queue(maxsize=2), threading.Event()

    def offer(value):
        while not stopped.is_set():
            try:
                messages.put(value, timeout=0.05)
                return
            except queue.Full:
                pass

    def read():
        try:
            while not stopped.is_set():
                chunk = process.stdout.read(8192)
                if not chunk:
                    break
                offer(chunk)
        finally:
            offer(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    data, error, truncated = bytearray(), None, False
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                error = "timeout"
                break
            try:
                chunk = messages.get(timeout=min(remaining, 0.05))
            except queue.Empty:
                continue
            if chunk is None:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
                if process.returncode != 0:
                    error = "command_failed"
                break
            space = max_bytes - len(data)
            data.extend(chunk[:space])
            if len(chunk) > space:
                truncated = True
                break
    except subprocess.TimeoutExpired:
        error = "timeout"
    finally:
        stopped.set()
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        reader.join(timeout=1)
        process.stdout.close()
    return CommandResult(bytes(data), error, truncated)


def sanitize_inspect(value):
    image, status, health, restarts = (
        value.get(k) for k in ("image", "status", "health", "restart_count")
    )
    return {
        "image": (
            image
            if isinstance(image, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", image)
            else None
        ),
        "status": (
            status
            if status
            in (
                "created",
                "running",
                "paused",
                "restarting",
                "removing",
                "exited",
                "dead",
            )
            else "unknown"
        ),
        "health": health if health in ("starting", "healthy", "unhealthy") else None,
        "restart_count": restarts if type(restarts) is int and restarts >= 0 else None,
    }


def _number(value, suffix=""):
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9]+(?:\.[0-9]+)?" + re.escape(suffix), value
    ):
        return None
    result = float(value[: -len(suffix)] if suffix else value)
    return result if math.isfinite(result) else None


def _bytes(value):
    match = re.fullmatch(
        r"([0-9]+(?:\.[0-9]+)?)(B|KiB|MiB|GiB|TiB|kB|MB|GB|TB)", value.strip()
    )
    if not match:
        return None
    scale = {
        "B": 1,
        "KiB": 1024,
        "MiB": 1024**2,
        "GiB": 1024**3,
        "TiB": 1024**4,
        "kB": 1000,
        "MB": 1000**2,
        "GB": 1000**3,
        "TB": 1000**4,
    }[match.group(2)]
    number = _number(match.group(1))
    return (
        int(number * scale) if number is not None and number * scale < 2**63 else None
    )


def sanitize_stats(value):
    memory = value.get("memory", "")
    parts = memory.split("/") if isinstance(memory, str) else []
    pids = value.get("pids", "")
    return {
        "cpu_percent": _number(value.get("cpu"), "%"),
        "memory_percent": _number(value.get("memory_percent"), "%"),
        "memory_bytes": _bytes(parts[0]) if len(parts) == 2 else None,
        "memory_limit_bytes": _bytes(parts[1]) if len(parts) == 2 else None,
        "pids": (
            int(pids)
            if isinstance(pids, str) and re.fullmatch(r"[0-9]{1,10}", pids)
            else None
        ),
    }


def _structured(result, sanitize):
    if result.error or result.byte_limit_reached:
        return {"error": result.error or "byte_limit", "value": None}
    try:
        value = json.loads(result.data)
        if not isinstance(value, dict):
            raise ValueError()
        return {"error": None, "value": sanitize(value)}
    except (ValueError, TypeError):
        return {"error": "invalid_shape", "value": None}


def collect_sample(
    *,
    window_seconds=300,
    tail_limit=10000,
    max_bytes=2 * 1024 * 1024,
    command_timeout=10,
    runner=run_bounded,
):
    if not (
        1 <= window_seconds <= 3600
        and 1 <= tail_limit <= 10000
        and 1024 <= max_bytes <= 8 * 1024 * 1024
        and 0 < command_timeout <= 30
    ):
        raise ValueError("Sample limits out of range")
    until = dt.datetime.now(dt.timezone.utc)
    since = until - dt.timedelta(seconds=window_seconds)
    rows = []
    for service, container in SERVICES.items():
        state = runner(
            ["docker", "inspect", "--format", INSPECT_FORMAT, container],
            max_bytes=16384,
            timeout=command_timeout,
        )
        logs = runner(
            [
                "docker",
                "logs",
                "--since",
                since.isoformat(),
                "--until",
                until.isoformat(),
                "--tail",
                str(tail_limit),
                container,
            ],
            max_bytes=max_bytes,
            timeout=command_timeout,
        )
        stats = runner(
            ["docker", "stats", "--no-stream", "--format", STATS_FORMAT, container],
            max_bytes=16384,
            timeout=command_timeout,
        )
        summary = None
        if logs.error in (None, "timeout"):
            text = logs.data.decode("utf-8", errors="replace")
            partial = (
                bool(text)
                and (logs.byte_limit_reached or logs.error == "timeout")
                and not text.endswith("\n")
            )
            summary = summarize_logs(
                text.splitlines(),
                tail_limit=tail_limit,
                byte_truncated=logs.byte_limit_reached,
                partial_last_line=partial,
                command_timeout=logs.error == "timeout",
            )
        rows.append(
            {
                "service": service,
                "runtime": _structured(state, sanitize_inspect),
                "resources": _structured(stats, sanitize_stats),
                "logs": {"error": logs.error, "summary": summary},
            }
        )
    return {
        "schema": 1,
        "since_utc": since.isoformat(),
        "until_utc": until.isoformat(),
        "observed_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "window_seconds": window_seconds,
        "limits": {
            "tail_lines_per_service": tail_limit,
            "log_bytes_per_service": max_bytes,
            "command_timeout_seconds": command_timeout,
        },
        "semantics": "HTTP observations only; recovery routes are not users; provider HTTP is not device delivery; uncompleted starts may cross window boundaries.",
        "services": rows,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window-seconds", type=int, default=300)
    parser.add_argument("--tail-limit", type=int, default=10000)
    parser.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024)
    parser.add_argument("--command-timeout", type=float, default=10)
    args = parser.parse_args(argv)
    try:
        result = collect_sample(**vars(args))
    except ValueError:
        parser.exit(2, "Sample limits out of range\n")
    print(json.dumps(result, indent=2, ensure_ascii=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
