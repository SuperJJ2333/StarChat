"""按 CID+kind 的限频：通知风暴收敛为一次实际下发，但来电优先。

规则（来电不被普通消息吞掉）：
- message：同 CID 1.5s 窗口只发一条（普通消息风暴合并）。
- call：独立更长间隔 500ms（仅对同一来电风暴去重——Synapse 对同一
  m.call.invite 可能重发 notify）；**不受 message 窗口影响**。
- 不同 kind 不互相吞；同一 kind 各自独立计数。
- P01：发送失败（临时错误）时调用 [release] 回滚该 (cid, kind) 的窗口
  标记——否则协议重试会被限频静默吞掉（资格已在失败前消耗）。
- 线程安全：推送现在经线程池有界并发分发，窗口表加锁保护。
"""
import threading
import time


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
            last = self._last_sent.get(key)
            if last is not None and (now - last[0]) * 1000 < interval_ms:
                return None
            self._revision += 1
            reservation = self._revision
            self._last_sent[key] = (now, reservation)
            self._prune_locked(now)
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
        if len(self._last_sent) > 8192:
            max_interval_ms = max(
                self._min_interval_ms, self._call_min_interval_ms
            )
            cutoff = now - (max_interval_ms / 1000.0)
            self._last_sent = {
                key: entry for key, entry in self._last_sent.items() if entry[0] > cutoff
            }
