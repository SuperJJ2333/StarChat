import pytest

from app.core.errors import AppError
from app.core.rate_limits import RedisRateLimiter
from app.api.identity import public_rate_limit_key


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


def test_public_auth_rate_limit_keys_are_scoped_without_exposing_identifiers() -> None:
    alice = public_rate_limit_key("auth:login", "203.0.113.1", "Alice")
    other_ip = public_rate_limit_key("auth:login", "203.0.113.2", "Alice")
    bob = public_rate_limit_key("auth:login", "203.0.113.1", "Bob")

    assert alice != other_ip
    assert alice != bob
    assert "alice" not in alice.casefold()
    assert "203.0.113.1" not in alice
