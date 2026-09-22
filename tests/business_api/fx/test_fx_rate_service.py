"""ADR-0076 批次1：FX 汇率参考服务（apihz，60 分钟持久缓存）。"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from concurrent.futures import ThreadPoolExecutor
import time

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker

from app.core.database import Base


@pytest.fixture
def db(tmp_path):
    # 临时文件库：并发用例需要多连接共享同一库（:memory: 每连接独立空库）。
    engine = create_engine(
        f"sqlite+pysqlite:///{tmp_path / 'fx.db'}",
        connect_args={"check_same_thread": False, "timeout": 15},
    )

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    import app.modules.fx.models  # noqa: F401  (注册 ORM 元数据后再建表)

    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    yield factory
    engine.dispose()


class FakeClock:
    def __init__(self):
        self._now = datetime(2026, 9, 21, 12, 0, 0, tzinfo=timezone.utc)

    def __call__(self):
        return self._now

    def advance(self, **kwargs):
        self._now = self._now + timedelta(**kwargs)


class FakeUpstream:
    """可编程上游：记录调用，返回预置响应或抛异常。"""

    def __init__(self, payload=None, exc=None, delay=0.0):
        self.calls = []
        self.payload = payload if payload is not None else {
            "code": 200, "rate": "7.12", "money": 10, "from": "USD", "to": "CNY", "uptime": "99.95%",
        }
        self.exc = exc
        self.delay = delay

    def __call__(self, url, timeout):
        self.calls.append({"url": url, "timeout": timeout})
        time.sleep(self.delay)
        if self.exc is not None:
            raise self.exc
        return self.payload


def make_service(db, upstream, clock, **kwargs):
    from app.modules.fx.service import FxService

    return FxService(
        db,
        api_id=kwargs.pop("api_id", "unit-id"),
        api_key=kwargs.pop("api_key", "unit-key"),
        http_get=upstream,
        now=clock,
        instance_id="test-instance",
        **kwargs,
    )


def test_first_request_fetches_upstream_and_caches(db):
    upstream, clock = FakeUpstream(), FakeClock()
    quote = make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")
    assert quote["rate"] == Decimal("7.120000")
    assert quote["stale"] is False
    assert quote["upstream_uptime"] == "99.95%"
    assert len(upstream.calls) == 1
    with db() as session:
        from app.modules.fx.models import FxRate

        row = session.get(FxRate, "USD/CNY")
        assert row is not None and Decimal(row.rate) == Decimal("7.120000")
        assert row.expires_at - row.fetched_at == timedelta(seconds=3600)


def test_within_60_minutes_hits_cache_without_upstream(db):
    upstream, clock = FakeUpstream(), FakeClock()
    service = make_service(db, upstream, clock)
    service.get_rate_snapshot(actor_id="alice")
    clock.advance(minutes=59)
    second = service.get_rate_snapshot(actor_id="bob")
    assert second["stale"] is False
    assert len(upstream.calls) == 1


def test_after_60_minutes_refreshes_on_demand(db):
    upstream, clock = FakeUpstream(), FakeClock()
    service = make_service(db, upstream, clock)
    service.get_rate_snapshot(actor_id="alice")
    clock.advance(minutes=61)
    service.get_rate_snapshot(actor_id="bob")
    assert len(upstream.calls) == 2


def test_no_user_request_no_upstream_call(db):
    upstream, clock = FakeUpstream(), FakeClock()
    make_service(db, upstream, clock)
    clock.advance(hours=5)
    assert upstream.calls == []


def test_concurrent_requests_share_single_upstream_call(db):
    """并发 100（此处 32）请求在过期窗口内只允许一次上游调用。"""
    upstream, clock = FakeUpstream(delay=0.3), FakeClock()
    service = make_service(db, upstream, clock)
    service.get_rate_snapshot(actor_id="warmup")
    calls_before = len(upstream.calls)
    clock.advance(minutes=61)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda i: service.get_rate_snapshot(actor_id=f"u{i}"), range(32)))
    assert len(upstream.calls) - calls_before == 1
    assert all(r["rate"] == Decimal("7.120000") for r in results)


def test_cache_survives_service_restart(db):
    upstream, clock = FakeUpstream(), FakeClock()
    make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")
    restarted = make_service(db, FakeUpstream(payload={"code": 200, "rate": "9.99"}), clock)
    quote = restarted.get_rate_snapshot(actor_id="bob")
    assert quote["rate"] == Decimal("7.120000")


def test_money_ten_result_field_is_never_used_as_unit_rate(db):
    """money=10 时 result 是 10 美元换算结果；缺 rate 时必须按 result/money 推导。"""
    upstream = FakeUpstream(payload={"code": 200, "result": 71.2, "money": 10, "from": "USD", "to": "CNY"})
    clock = FakeClock()
    quote = make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")
    assert quote["rate"] == Decimal("7.120000")


def test_derived_unit_rate_out_of_sane_range_rejected(db):
    """result/money 推导必须过结构/精度/合理性校验：900/10=90 合法，但 9e6/10=9e5 越界拒绝。"""
    upstream = FakeUpstream(payload={"code": 200, "result": 9000000, "money": 10})
    clock = FakeClock()
    with pytest.raises(Exception) as excinfo:
        make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")
    assert getattr(excinfo.value, "code", "") == "FX_UNAVAILABLE"


def test_wrong_direction_rejected(db):
    upstream = FakeUpstream(payload={"code": 200, "rate": "7.12", "from": "CNY", "to": "USD"})
    clock = FakeClock()
    with pytest.raises(Exception):
        make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")


def test_non_positive_rate_rejected(db):
    upstream = FakeUpstream(payload={"code": 200, "rate": "0"})
    clock = FakeClock()
    with pytest.raises(Exception):
        make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")


def test_rate_field_preferred_over_result(db):
    upstream = FakeUpstream(payload={"code": 200, "rate": "7.15", "result": "99", "money": 10})
    clock = FakeClock()
    quote = make_service(db, upstream, clock).get_rate_snapshot(actor_id="alice")
    assert quote["rate"] == Decimal("7.150000")


def test_upstream_failure_does_not_write_fake_rate_and_keeps_last_good(db):
    good, clock = FakeUpstream(), FakeClock()
    service = make_service(db, good, clock)
    service.get_rate_snapshot(actor_id="alice")
    clock.advance(minutes=61)
    bad = FakeUpstream(payload=None, exc=TimeoutError("upstream timeout"))
    service.http_get = bad
    quote = service.get_rate_snapshot(actor_id="bob")
    assert quote["stale"] is True and quote["rate"] == Decimal("7.120000")
    with db() as session:
        from app.modules.fx.models import FxRate

        row = session.get(FxRate, "USD/CNY")
        assert Decimal(row.rate) == Decimal("7.120000")
        assert row.last_error_code is not None


def test_failure_backoff_within_window_does_not_retry_upstream(db):
    good, clock = FakeUpstream(), FakeClock()
    service = make_service(db, good, clock)
    service.get_rate_snapshot(actor_id="alice")
    clock.advance(minutes=61)
    bad = FakeUpstream(payload=None, exc=TimeoutError("boom"))
    service.http_get = bad
    service.get_rate_snapshot(actor_id="bob")
    assert len(bad.calls) == 1
    clock.advance(minutes=10)
    quote = service.get_rate_snapshot(actor_id="carol")
    assert len(bad.calls) == 1
    assert quote["stale"] is True


def test_failure_without_any_snapshot_raises_unavailable(db):
    bad = FakeUpstream(payload=None, exc=TimeoutError("boom"))
    clock = FakeClock()
    service = make_service(db, bad, clock)
    with pytest.raises(Exception) as excinfo:
        service.get_rate_snapshot(actor_id="alice")
    assert getattr(excinfo.value, "code", "") == "FX_UNAVAILABLE"


def test_url_and_errors_mask_api_key(db):
    from app.modules.fx.service import masked_url

    leaked = "https://cn.apihz.cn/api/jinrong/huilv.php?from=USD&to=CNY&money=10&id=unit-id&key=unit-key"
    masked = masked_url(leaked)
    assert "unit-key" not in masked and "unit-id" not in masked
    bad = FakeUpstream(payload=None, exc=RuntimeError(leaked))
    clock = FakeClock()
    service = make_service(db, bad, clock)
    with pytest.raises(Exception) as excinfo:
        service.get_rate_snapshot(actor_id="alice")
    message = str(getattr(excinfo.value, "message", "")) + str(getattr(excinfo.value, "code", ""))
    assert "unit-key" not in message and "unit-id" not in message


def test_missing_credentials_fail_closed(db):
    from app.modules.fx.service import FxService

    clock = FakeClock()
    service = FxService(db, api_id=None, api_key=None, http_get=FakeUpstream(), now=clock, instance_id="t")
    with pytest.raises(Exception) as excinfo:
        service.get_rate_snapshot(actor_id="alice")
    assert getattr(excinfo.value, "code", "") == "FX_NOT_CONFIGURED"
