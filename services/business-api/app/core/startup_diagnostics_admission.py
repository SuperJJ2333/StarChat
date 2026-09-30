"""Atomic, capacity-bounded admission for untrusted startup observations."""
import hashlib
from typing import Literal, Protocol
from uuid import uuid4

from redis import Redis

AdmissionResult = tuple[Literal['new', 'duplicate', 'busy', 'limited'], str | None]


class StartupDiagnosticsAdmission(Protocol):
    def check_source(self, source: str) -> bool: ...
    def reserve(self, event_id: str) -> AdmissionResult: ...
    def complete(self, event_id: str, token: str) -> bool: ...
    def release(self, event_id: str, token: str) -> None: ...


# No per-event Redis keys. Global admission precedes even source-key allocation.
# All mutations including counter TTL repair happen within one atomic execution.
_CHECK_SOURCE = """
local global = redis.call('INCR', KEYS[1])
if redis.call('TTL', KEYS[1]) < 0 then redis.call('EXPIRE', KEYS[1], 60) end
if global > 120 then return 0 end
local source = redis.call('INCR', KEYS[2])
if redis.call('TTL', KEYS[2]) < 0 then redis.call('EXPIRE', KEYS[2], 60) end
if source > 10 then return 0 end
return 1
"""

_RESERVE = """
local now = tonumber(redis.call('TIME')[1])
local expired = redis.call('ZRANGEBYSCORE', KEYS[1], '-inf', now, 'LIMIT', 0, 128)
for _, id in ipairs(expired) do
    redis.call('ZREM', KEYS[1], id)
    redis.call('HDEL', KEYS[2], id)
end
-- The requested UUID may fall outside the bounded batch. Its own expiry
-- remains authoritative; orphan state must not acknowledge a lost report.
local target_expiry = redis.call('ZSCORE', KEYS[1], ARGV[1])
if not target_expiry or tonumber(target_expiry) <= now then
    redis.call('ZREM', KEYS[1], ARGV[1])
    redis.call('HDEL', KEYS[2], ARGV[1])
end
local state = redis.call('HGET', KEYS[2], ARGV[1])
if state == 'd' then return {'duplicate', ''} end
if state then
    local until_at = tonumber(string.match(state, '^p:(%d+):'))
    if until_at and until_at > now then return {'busy', ''} end
end
if not state and redis.call('ZCARD', KEYS[1]) >= 10000 then return {'limited', ''} end
redis.call('ZADD', KEYS[1], now + 86400, ARGV[1])
redis.call('HSET', KEYS[2], ARGV[1], 'p:' .. (now + 15) .. ':' .. ARGV[2])
redis.call('EXPIRE', KEYS[1], 86415)
redis.call('EXPIRE', KEYS[2], 86415)
return {'new', ARGV[2]}
"""

_COMPLETE = """
local now = tonumber(redis.call('TIME')[1])
local state = redis.call('HGET', KEYS[2], ARGV[1])
if not state then return 0 end
local until_at, token = string.match(state, '^p:(%d+):(.+)$')
if not until_at or token ~= ARGV[2] or tonumber(until_at) <= now then return 0 end
redis.call('HSET', KEYS[2], ARGV[1], 'd')
redis.call('ZADD', KEYS[1], now + 86400, ARGV[1])
redis.call('EXPIRE', KEYS[1], 86415)
redis.call('EXPIRE', KEYS[2], 86415)
return 1
"""

_RELEASE = """
local state = redis.call('HGET', KEYS[2], ARGV[1])
if state then
    local token = string.match(state, '^p:%d+:(.+)$')
    if token == ARGV[2] then
        redis.call('HDEL', KEYS[2], ARGV[1])
        redis.call('ZREM', KEYS[1], ARGV[1])
    end
end
return 1
"""


class RedisStartupDiagnosticsAdmission:
    def __init__(self, client: Redis, *, namespace: str = 'liuhetong:{startup-diagnostics}'):
        self._client = client
        self.namespace = namespace
        self._check_source = client.register_script(_CHECK_SOURCE)
        self._reserve = client.register_script(_RESERVE)
        self._complete = client.register_script(_COMPLETE)
        self._release = client.register_script(_RELEASE)

    @classmethod
    def from_url(cls, redis_url: str) -> 'RedisStartupDiagnosticsAdmission':
        return cls(Redis.from_url(redis_url, decode_responses=True,
                                 socket_connect_timeout=2, socket_timeout=2))

    def close(self) -> None:
        self._client.close()

    def _dedup_keys(self) -> list[str]:
        return [self.namespace + ':expiries', self.namespace + ':states']

    def check_source(self, source: str) -> bool:
        # Connection address is used only for a short-lived counter, never logged.
        source_digest = hashlib.sha256(source.encode('utf-8')).hexdigest()
        keys = [self.namespace + ':global', self.namespace + ':source:' + source_digest]
        return bool(self._check_source(keys=keys))

    def reserve(self, event_id: str) -> AdmissionResult:
        result, token = self._reserve(keys=self._dedup_keys(), args=[event_id, str(uuid4())])
        return result, token or None

    def admit(self, event_id: str, source: str) -> AdmissionResult:
        """Convenience for validated callers; HTTP receiver checks before reading."""
        if not self.check_source(source):
            return 'limited', None
        return self.reserve(event_id)

    def complete(self, event_id: str, token: str) -> bool:
        return bool(self._complete(keys=self._dedup_keys(), args=[event_id, token]))

    def release(self, event_id: str, token: str) -> None:
        self._release(keys=self._dedup_keys(), args=[event_id, token])
