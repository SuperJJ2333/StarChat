"""按 CID+kind 的限频：通知风暴收敛为一次实际下发，但来电优先。

规则（来电不被普通消息吞掉）：
- message：同 CID 1.5s 窗口只发一条（普通消息风暴合并）。
- call：独立更长间隔 500ms（仅对同一来电风暴去重——Synapse 对同一
  m.call.invite 可能重发 notify）；**不受 message 窗口影响**。
- 不同 kind 不互相吞；同一 kind 各自独立计数。
"""
import time


class CidRateLimiter:
    def __init__(self, min_interval_ms: int, call_min_interval_ms: int | None = None):
        self._min_interval_ms = min_interval_ms
        self._call_min_interval_ms = (
            call_min_interval_ms if call_min_interval_ms is not None else 500
        )
        # {(cid, kind): last_sent_monotonic}
        self._last_sent: dict[tuple[str, str], float] = {}

    def allow(self, cid: str, kind: str = "message") -> bool:
        """同 (cid, kind) 在窗口内的后续推送丢弃（返回 False）。

        来电（kind=call）用独立的短窗口，不会被普通消息的长窗口吞掉。
        """
        interval_ms = (
            self._call_min_interval_ms
            if kind == "call"
            else self._min_interval_ms
        )
        if interval_ms <= 0:
            return True
        key = (cid, kind)
        now = time.monotonic()
        last = self._last_sent.get(key)
        if last is not None and (now - last) * 1000 < interval_ms:
            return False
        self._last_sent[key] = now
        self._prune(now)
        return True

    def _prune(self, now: float) -> None:
        # 防止字典无限增长：粗裁剪。
        if len(self._last_sent) > 8192:
            max_interval_ms = max(
                self._min_interval_ms, self._call_min_interval_ms
            )
            cutoff = now - (max_interval_ms / 1000.0)
            self._last_sent = {
                key: at for key, at in self._last_sent.items() if at > cutoff
            }
