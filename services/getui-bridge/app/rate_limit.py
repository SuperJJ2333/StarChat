"""同 CID 最小下发间隔：通知风暴收敛为一次实际下发。"""
import time


class CidRateLimiter:
    def __init__(self, min_interval_ms: int):
        self._min_interval_ms = min_interval_ms
        self._last_sent: dict[str, float] = {}

    def allow(self, cid: str) -> bool:
        """同 CID 在窗口内的后续推送一律丢弃（返回 False）。"""
        if self._min_interval_ms <= 0:
            return True
        now = time.monotonic()
        last = self._last_sent.get(cid)
        if last is not None and (now - last) * 1000 < self._min_interval_ms:
            return False
        self._last_sent[cid] = now
        # 防止字典无限增长：粗裁剪（保留最近 4096 个键）。
        if len(self._last_sent) > 8192:
            cutoff = now - (self._min_interval_ms / 1000.0)
            self._last_sent = {
                cid: at for cid, at in self._last_sent.items() if at > cutoff
            }
        return True
