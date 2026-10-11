"""有界推送准入：v1 按会话/房间限频并独立去重事件。

Legacy/call 兼容规则（来电不被普通消息吞掉）：
- message：同 CID 1.5s 窗口只发一条（普通消息风暴合并）。
- call：独立更长间隔 500ms（仅对同一来电风暴去重——Synapse 对同一
  m.call.invite 可能重发 notify）；**不受 message 窗口影响**。
- 不同 kind 不互相吞；同一 kind 各自独立计数。
- P01：发送失败（临时错误）时调用 [release] 回滚该 (cid, kind) 的窗口
  标记——否则协议重试会被限频静默吞掉（资格已在失败前消耗）。
- 线程安全：推送现在经线程池有界并发分发，窗口表加锁保护。
"""
from collections import OrderedDict
from enum import Enum
import threading
import time

from .notify import NativeEnvelope


MAX_TRACKED_ENTRIES = 8192


class RateLimitCapacityError(Exception):
    """No bounded state slot is available; the gateway must request a retry."""


class CidRateLimiter:
    def __init__(self, min_interval_ms: int, call_min_interval_ms: int | None = None):
        self._min_interval_ms = min_interval_ms
        self._call_min_interval_ms = (
            call_min_interval_ms if call_min_interval_ms is not None else 500
        )
        # {(cid, kind): last_sent_monotonic}
        self._last_sent: dict[tuple[str, str], tuple[float, int]] = {}
        self._revision = 0
        self._lock = threading.Lock()

    def allow(self, cid: str, kind: str = "message") -> bool:
        """同 (cid, kind) 在窗口内的后续推送丢弃（返回 False）。"""
        return self.reserve(cid, kind) is not None

    def reserve(self, cid: str, kind: str = "message") -> int | None:
        """Return a bounded-table reservation token for concurrency-safe release."""
        interval_ms = (
            self._call_min_interval_ms
            if kind == "call"
            else self._min_interval_ms
        )
        key = (cid, kind)
        now = time.monotonic()
        with self._lock:
            self._prune_locked(now)
            last = self._last_sent.get(key)
            if last is not None and (now - last[0]) * 1000 < interval_ms:
                return None
            if key not in self._last_sent and len(self._last_sent) >= MAX_TRACKED_ENTRIES:
                raise RateLimitCapacityError
            self._revision += 1
            reservation = self._revision
            self._last_sent[key] = (now, reservation)
            return reservation

    def release(self, cid: str, kind: str = "message", *, reservation: int | None = None) -> None:
        """P01：本次发送实际失败时回滚窗口标记，允许协议重试真正重发。

        Concurrent delivery must provide its reserve() token: an older failed
        request cannot remove a newer successful window. Omitted tokens retain
        the original synchronous compatibility API, not used by async delivery.
        """
        with self._lock:
            key = (cid, kind)
            current = self._last_sent.get(key)
            if current is not None and (reservation is None or current[1] == reservation):
                self._last_sent.pop(key, None)

    def _prune_locked(self, now: float) -> None:
        # 防止字典无限增长：粗裁剪（调用方已持锁）。
        if len(self._last_sent) >= MAX_TRACKED_ENTRIES:
            max_interval_ms = max(
                self._min_interval_ms, self._call_min_interval_ms
            )
            cutoff = now - (max_interval_ms / 1000.0)
            self._last_sent = {
                key: entry for key, entry in self._last_sent.items() if entry[0] > cutoff
            }


class NativeResult(Enum):
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    RETRY = "retry"


class NativeMessageLimiter:
    """Separate per-room opportunities from per-event terminal results.

    Unsent and in-flight events are never acknowledged as successful. Completed
    outcomes live for at least the configured provider TTL, without eviction to
    admit new work. Full tables return RETRY. In-flight entries cannot expire
    while their bounded provider worker is still running.
    """

    def __init__(self, min_interval_ms: int, ttl_ms: int):
        self._interval = max(0, min_interval_ms) / 1000.0
        self._ttl = max(300_000, ttl_ms) / 1000.0
        self._rooms: OrderedDict[tuple[str, ...], tuple[float, int]] = OrderedDict()
        self._completed: OrderedDict[tuple[str, ...], tuple[float, NativeResult]] = OrderedDict()
        self._pending: dict[tuple[str, ...], int] = {}
        self._revision = 0
        self._lock = threading.Lock()

    @staticmethod
    def _keys(cid: str, envelope: NativeEnvelope) -> tuple[tuple[str, ...], tuple[str, ...]]:
        room = (cid, envelope.scope, envelope.room_key)
        return room, (*room, envelope.event_key)

    def reserve(self, cid: str, envelope: NativeEnvelope) -> int | NativeResult:
        room, event = self._keys(cid, envelope)
        with self._lock:
            now = time.monotonic()
            # Both ordered tables have uniform TTLs and monotonic insertion.
            for table in (self._rooms, self._completed):
                while table and next(iter(table.values()))[0] <= now:
                    table.popitem(last=False)
            completed = self._completed.get(event)
            if completed is not None:
                return completed[1]
            if event in self._pending or room in self._rooms:
                return NativeResult.RETRY
            if (len(self._rooms) >= MAX_TRACKED_ENTRIES
                    or len(self._pending) + len(self._completed) >= MAX_TRACKED_ENTRIES):
                return NativeResult.RETRY
            self._revision += 1
            self._pending[event] = self._revision
            self._rooms[room] = (now + self._interval, self._revision)
            return self._revision

    def finish(self, cid: str, envelope: NativeEnvelope, reservation: int,
               outcome: NativeResult) -> None:
        room, event = self._keys(cid, envelope)
        with self._lock:
            if self._pending.get(event) != reservation:
                return
            del self._pending[event]
            if outcome is NativeResult.RETRY:
                current = self._rooms.get(room)
                if current is not None and current[1] == reservation:
                    del self._rooms[room]
            else:
                self._completed[event] = (time.monotonic() + self._ttl, outcome)
