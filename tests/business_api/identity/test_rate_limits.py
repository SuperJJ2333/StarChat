import pytest

from app.core.errors import AppError
from app.core.rate_limits import RedisRateLimiter


class FakePipeline:
    def __init__(self, client):
        self.client = client
        self.key = None

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def incr(self, key):
        self.key = key
        return self

    def ttl(self, key):
        self.key = key
        return self

    def execute(self):
        self.client.count += 1
        return [self.client.count, self.client.ttl]


class FakeRedis:
    def __init__(self):
        self.count = 0
        self.ttl = -1
        self.expirations = []

    def pipeline(self, transaction=True):
        assert transaction is True
        return FakePipeline(self)

    def expire(self, key, seconds):
        self.ttl = seconds
        self.expirations.append((key, seconds))


def test_redis_rate_limiter_sets_window_and_rejects_excess() -> None:
    redis = FakeRedis()
    limiter = RedisRateLimiter(redis)

    limiter.hit("auth:login:alice", limit=2, window_seconds=60)
    limiter.hit("auth:login:alice", limit=2, window_seconds=60)
    with pytest.raises(AppError) as exc_info:
        limiter.hit("auth:login:alice", limit=2, window_seconds=60)

    assert redis.expirations == [("liuhetong:rate:auth:login:alice", 60)]
    assert exc_info.value.code == "RATE_LIMITED"
