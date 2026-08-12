from dataclasses import dataclass
from typing import Protocol

from redis import Redis

from app.core.errors import AppError


class RateLimiter(Protocol):
    def hit(self, key: str, *, limit: int, window_seconds: int) -> None: ...


class NoopRateLimiter:
    def hit(self, key: str, *, limit: int, window_seconds: int) -> None:
        return None


class RedisRateLimiter:
    def __init__(self, client: Redis, namespace: str = "liuhetong:rate") -> None:
        self._client = client
        self._namespace = namespace

    @classmethod
    def from_url(cls, redis_url: str) -> "RedisRateLimiter":
        return cls(Redis.from_url(redis_url, decode_responses=True))

    def hit(self, key: str, *, limit: int, window_seconds: int) -> None:
        redis_key = f"{self._namespace}:{key}"
        with self._client.pipeline(transaction=True) as pipeline:
            pipeline.incr(redis_key)
            pipeline.ttl(redis_key)
            count, ttl = pipeline.execute()
        if ttl < 0:
            self._client.expire(redis_key, window_seconds)
        if count > limit:
            raise AppError(
                code="RATE_LIMITED",
                message="请求过于频繁，请稍后再试",
                status_code=429,
            )
