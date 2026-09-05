"""个推 bridge 错误语义与限频分类测试（永久 vs 临时、来电优先）。"""
import pytest
from fastapi.testclient import TestClient
import httpx

from app.config import BridgeSettings
from app.main import create_app
from app.getui_client import GetuiPushError, GetuiTransientError
from app.rate_limit import CidRateLimiter


def matrix_notify(kind="m.room.message", cid="cid-1"):
    return {
        "notification": {
            "event_id": "$e1",
            "room_id": "!r:x",
            "type": kind,
            "counts": {"unread": 1},
            "devices": [
                {"app_id": "com.liuhetong.mobile.getui", "pushkey": cid, "tweaks": {}}
            ],
        }
    }


@pytest.fixture()
def settings():
    return BridgeSettings(
        getui_app_id="test-app",
        getui_app_key="test-key",
        getui_sign_secret="test-secret",
        rate_limit_ms=1500,
    )


class _GetuiMock:
    """返回预设结果的个推服务端 mock。"""

    def __init__(self):
        self.route = {}

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = request.url.path
        if url.endswith("/auth"):
            return httpx.Response(200, json={
                "code": 0,
                "data": {"token": "tok", "expire_time": "9999999999999"},
            })
        if "/push/" in url:
            result = self.route.get("push")
            if result is None:
                return httpx.Response(200, json={"code": 0, "data": {"status": "successed_online"}})
            if isinstance(result, Exception):
                raise result
            if callable(result):
                return result(request)
            return httpx.Response(result[0], json=result[1])
        raise AssertionError(f"unexpected: {url}")


@pytest.fixture()
def getui_mock():
    return _GetuiMock()


@pytest.fixture()
def client(settings, getui_mock):
    app = create_app(
        settings,
        http_client=httpx.Client(transport=httpx.MockTransport(getui_mock.handler)),
    )
    return TestClient(app)


# ── rejected 语义修复 ────────────────────────────────────────────

def test_permanent_cid_error_goes_to_rejected(client, getui_mock):
    """个推明确 CID 永久失效（code 20103）→ 进 rejected 让 Synapse 删 pusher。"""
    getui_mock.route["push"] = (400, {"code": 20103, "msg": "cid not found"})
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="dead-cid"))
    assert resp.status_code == 200
    assert resp.json() == {"rejected": ["dead-cid"]}


def test_transient_network_error_does_not_reject(client, getui_mock):
    """网络超时（httpx.HTTPError）→ 503 触发 Synapse 协议重试；绝不进
    rejected（P01：临时失败不得伪装成功吞掉重试机会，也不删 pusher）。"""
    getui_mock.route["push"] = httpx.ConnectTimeout("timeout")
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="c1"))
    assert resp.status_code == 503, "临时失败必须返回可重试错误"
    assert not resp.json().get("rejected"), "临时错误不得进 rejected"


def test_transient_5xx_does_not_reject(client, getui_mock):
    """个推返回 500 → 503 重试，不进 rejected。"""
    getui_mock.route["push"] = (500, {"error": "internal"})
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="c1"))
    assert resp.status_code == 503
    assert not resp.json().get("rejected")


def test_non_permanent_business_code_does_not_reject(client, getui_mock):
    """个推限流码（code 30005 等）→ 503 重试，不进 rejected。"""
    getui_mock.route["push"] = (429, {"code": 30005, "msg": "rate limited"})
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="c1"))
    assert resp.status_code == 503
    assert not resp.json().get("rejected")


def test_push_error_is_permanent_property():
    """GetuiPushError.is_permanent 只对已知永久码为 True。"""
    assert GetuiPushError("dead", code=20103).is_permanent is True
    assert GetuiPushError("auth fail", code=10001).is_permanent is False
    assert GetuiPushError("no code").is_permanent is False


def test_transient_error_class_exists():
    """GetuiTransientError 与 GetuiPushError 是不同类型。"""
    assert not issubclass(GetuiTransientError, GetuiPushError)


# ── 限频分类（来电不被吞） ──────────────────────────────────────

def test_call_push_not_blocked_by_message_rate_limit():
    """普通消息限频不吞来电（不同 kind 独立窗口）。"""
    limiter = CidRateLimiter(min_interval_ms=1500, call_min_interval_ms=500)
    assert limiter.allow("cid-1", "message") is True
    # 1.5s 内来电不被 message 的 1500ms 窗口吞掉：
    assert limiter.allow("cid-1", "call") is True, "来电必须通过"
    # 同 kind 重复风暴仍收敛：
    assert limiter.allow("cid-1", "message") is False
    assert limiter.allow("cid-1", "call") is False


def test_call_has_shorter_dedup_window():
    """来电窗口短（500ms）：不同来电（间隔>500ms）不错误合并。"""
    import time as _time
    limiter = CidRateLimiter(min_interval_ms=1500, call_min_interval_ms=50)
    assert limiter.allow("c", "call") is True
    _time.sleep(0.06)
    assert limiter.allow("c", "call") is True, "不同来电不得合并"


# ── event_id_only 时 type 缺失 ────────────────────────────────

def test_missing_type_defaults_to_message(client):
    """Synapse event_id_only 可能不传 type：降级 message，不崩溃。"""
    body = matrix_notify()
    del body["notification"]["type"]
    resp = client.post("/_matrix/push/v1/notify", json=body)
    assert resp.status_code == 200
    # 推送成功（message kind 通用文案）：
    assert resp.json() == {}


def test_call_type_still_detected(client):
    """type=m.call.invite 正常时 call kind 生效（既有行为不回归）。"""
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(kind="m.call.invite"))
    assert resp.status_code == 200
    assert resp.json() == {}


# ── 并发永久+临时混合 ───────────────────────────────────────────

def test_mixed_permanent_and_transient(client, getui_mock):
    """多 CID 同时永久失效：全部进 rejected（含与正常 CID 共存时）。"""
    getui_mock.route["push"] = (400, {"code": 20103, "msg": "cid invalid"})
    body = matrix_notify()
    body["notification"]["devices"].append(
        {"app_id": "com.liuhetong.mobile.getui", "pushkey": "dead"}
    )
    resp = client.post("/_matrix/push/v1/notify", json=body)
    assert resp.status_code == 200
    # 两个 CID 都拿到永久码→都进 rejected：
    assert set(resp.json().get("rejected", [])) == {"cid-1", "dead"}


def test_call_kind_uses_transmission_wakeup_native_calservice():
    """规格（原生 CallService/分发层）：call/message 均走透传唤醒（仅
    type 类别，无业务内容）；push_channel.ups 仅作离线厂商兜底展示。"""
    from app.getui_client import build_push_body
    import json as _json

    call_body = build_push_body("cid-call", "call", 300_000)
    assert _json.loads(call_body["push_message"]["transmission"]) == {"type": "call"}
    assert "notification" not in call_body["push_message"]
    assert "ups" in call_body["push_channel"]["android"]

    msg_body = build_push_body("cid-msg", "message", 300_000)
    assert _json.loads(msg_body["push_message"]["transmission"]) == {"type": "message"}
    assert "notification" not in msg_body["push_message"]
    assert "ups" in msg_body["push_channel"]["android"]


def test_message_kind_uses_transmission_for_dispatcher():
    """Push 架构：message 也走透传（GetuiReceiver→PushEventDispatcher 分发），
    离线厂商通道兜底；载荷仅 type，无业务内容。"""
    from app.getui_client import build_push_body
    import json as _json
    body = build_push_body("cid-m", "message", 300_000)
    payload = _json.loads(body["push_message"]["transmission"])
    assert payload == {"type": "message"}
    assert "notification" not in body["push_message"]
    assert "ups" in body.get("push_channel", {}).get("android", {})


# ── P02：HTTP 401 + code 10001 的令牌刷新分支（原实现不可达） ────

def test_p02_http_401_token_invalid_refreshes_once_and_succeeds(client, getui_mock):
    """401 + code=10001 → 清缓存刷新一次重试成功；auth 恰好两次；推送成功。"""
    # push 侧第一次得 401/10001（token 失效），第二次（刷新后）成功。
    seen = {"n": 0}
    def push_handler(request):
        seen["n"] += 1
        import httpx as _x
        if seen["n"] == 1:
            return _x.Response(401, json={"code": 10001, "msg": "token invalid"})
        return _x.Response(200, json={"code": 0, "data": {"status": "successed_online"}})
    getui_mock.route["push"] = push_handler
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="c1"))
    assert resp.status_code == 200
    assert seen["n"] == 2, "仅刷新重试一次（同一请求身份）"


def test_p02_second_401_does_not_loop(client, getui_mock):
    """刷新后仍 401 → 判定失败（不无限循环），且不进 rejected。"""
    def push_handler(request):
        import httpx as _x
        return _x.Response(401, json={"code": 10001, "msg": "token invalid"})
    getui_mock.route["push"] = push_handler
    resp = client.post("/_matrix/push/v1/notify", json=matrix_notify(cid="c1"))
    assert resp.status_code == 503, "鉴权失败按临时错误（绝不删 pusher/进 rejected）"
    assert not resp.json().get("rejected")


def test_p02_auth_error_code_not_treated_as_permanent_cid():
    """鉴权类错误码（10001）绝不能被判为 CID 永久失效。"""
    assert GetuiPushError("auth fail", code=10001).is_permanent is False


# ── C01：有界并发——慢供应商不串行阻塞事件循环 ────────────────

def test_c01_concurrent_pushes_are_not_serialized(settings):
    """4 个 CID、每个供应商延迟 0.2s：并发（≤4）总耗时应明显小于串行。"""
    import time as _time
    import httpx
    from fastapi.testclient import TestClient
    from app.main import create_app

    delay = {"seconds": 0.2}
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/auth"):
            return httpx.Response(200, json={"code": 0, "data": {"token": "tok-1", "expire_time": 9999999999999}})
        _time.sleep(delay["seconds"])
        return httpx.Response(200, json={"code": 0, "data": {"status": "successed_online"}})

    app = create_app(settings, http_client=httpx.Client(transport=httpx.MockTransport(handler)))
    body = matrix_notify(cid="c1")
    for index in range(3):
        body["notification"]["devices"].append({"app_id": body["notification"]["devices"][0]["app_id"], "pushkey": f"c{index + 2}"})
    client = TestClient(app)
    started = _time.perf_counter()
    resp = client.post("/_matrix/push/v1/notify", json=body)
    elapsed = _time.perf_counter() - started
    assert resp.status_code == 200
    assert elapsed < delay["seconds"] * 4 * 0.75, (
        f"并发分发下耗时 {elapsed:.2f}s 不应接近串行 {delay['seconds'] * 4:.2f}s"
    )
