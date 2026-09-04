"""getui-bridge：Matrix Push Gateway → 个推桥接。

安全边界（本服务的存在意义）：
- 入站丢弃 Matrix 通知的全部业务内容（event_id/room_id/正文/发送者…）；
- 出站到个推的载荷只含：CID、随机 notify_id、消息类型（体现在通用文案）、
  有效期（settings.ttl）；文案仅"您有一条新消息"/"您有一个来电"；
- AppKey/签名密钥仅来自环境变量，绝不写日志。
"""
import dataclasses
import hashlib
import json
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

from app.config import BridgeSettings
from app.main import create_app
from app.notify import sanitize_notification


@pytest.fixture()
def settings(tmp_path):
    return BridgeSettings(
        getui_app_id="test-app-id",
        getui_app_key="test-app-key",
        getui_sign_secret="test-sign-secret",
        rate_limit_ms=0,
    )


@pytest.fixture()
def fake_getui():
    """记录出站请求的伪个推服务端。"""
    class _FakeGetui:
        def __init__(self):
            self.auth_calls = []
            self.push_calls = []
            self.push_response = {"code": 0, "data": {"status": "successed_online"}}

        def handler(self, request: httpx.Request) -> httpx.Response:
            from httpx import Response
            url = request.url.path
            if url.endswith("/auth"):
                self.auth_calls.append(json.loads(request.content))
                return Response(200, json={
                    "code": 0,
                    "data": {"token": "tok-1", "expire_time": "9999999999999"},
                })
            if "/push/" in url:
                self.push_calls.append({
                    "path": url,
                    "headers": dict(request.headers),
                    "body": json.loads(request.content),
                })
                return Response(200, json=self.push_response)
            raise AssertionError(f"unexpected getui call: {url}")

    return _FakeGetui()


def matrix_notify(app_id="com.liuhetong.mobile.getui", pushkey="cid-1", event_type="m.room.message"):
    return {
        "notification": {
            "event_id": "$secret-event-id",
            "room_id": "!secret-room:matrix.example",
            "type": event_type,
            "sender": "@secret-sender:matrix.example",
            "sender_display_name": "秘密发送者",
            "content": {"body": "秘密消息正文"},
            "room_name": "秘密群名称",
            "counts": {"unread": 3},
            "devices": [{"app_id": app_id, "pushkey": pushkey, "tweaks": {}}],
        }
    }


import httpx  # noqa: E402


@pytest.fixture()
def client(settings, fake_getui):
    app = create_app(settings, http_client=httpx.Client(transport=httpx.MockTransport(fake_getui.handler)))
    return TestClient(app)


class TestSanitize:
    def test_inbound_business_fields_are_discarded(self):
        spec = sanitize_notification(matrix_notify(), "com.liuhetong.mobile.getui")
        assert spec is not None
        # 出站规格只保留：kind 与推送目标（CID 在 devices 中）。
        assert {f: getattr(spec, f) for f in ('kind', 'cids')} == {
            'kind': spec.kind,
            'cids': spec.cids,
        }  # dataclass 仅有 kind/cids 两字段（下方逐项断言值）
        assert dataclasses.asdict(spec).keys() == {"kind", "cids"}, "出站规格只允许 kind/cids"
        assert spec.kind == "message"
        assert spec.cids == ["cid-1"]
        # 反序列化演示：业务字段必须全部丢失
        assert "room_id" not in dataclasses.asdict(spec)

    def test_call_type_maps_to_call_kind(self):
        spec = sanitize_notification(matrix_notify(event_type="m.call.invite"), "com.liuhetong.mobile.getui")
        assert spec.kind == "call"

    def test_other_app_ids_are_ignored(self):
        assert sanitize_notification(matrix_notify(app_id="com.other.app"), "com.liuhetong.mobile.getui") is None

    def test_missing_devices_returns_none(self):
        body = matrix_notify()
        body["notification"]["devices"] = []
        assert sanitize_notification(body, "com.liuhetong.mobile.getui") is None


class TestNotifyEndpoint:
    def test_outbound_payload_whitelist(self, client, fake_getui):
        resp = client.post("/_matrix/push/v1/notify", json=matrix_notify())
        assert resp.status_code == 200

        assert len(fake_getui.push_calls) == 1
        body = fake_getui.push_calls[0]["body"]
        # 顶层白名单。
        assert set(body.keys()) == {
            "request_id",
            "settings",
            "audience",
            "push_message",
            "push_channel",
        }
        # 在线通道：透传唤醒指令（仅 type，无业务内容）。
        assert set(body["push_message"].keys()) == {"transmission"}
        import json as _json

        assert _json.loads(body["push_message"]["transmission"]) == {"type": "message"}
        # 离线厂商通道兜底：仅通用文案 + startapp + 随机 notify_id。
        note = body["push_channel"]["android"]["ups"]["notification"]
        assert set(note.keys()) == {"title", "body", "click_type", "notify_id"}
        assert note["title"] == "畅聊"
        assert note["body"] == "您有一条新消息"
        assert note["click_type"] == "startapp"
        assert isinstance(note["notify_id"], int)
        # 厂商通道（离线兜底）同样只有通用文案。
        ups = body["push_channel"]["android"]["ups"]["notification"]
        assert set(ups.keys()) == {"title", "body", "click_type", "notify_id"}
        assert ups["click_type"] == "startapp"
        # 有效期（短 TTL，默认 300s）。
        assert body["settings"]["ttl"] == 300_000
        # 目标是 CID。
        assert body["audience"]["cid"] == ["cid-1"]

    def test_no_business_content_in_outbound_wire(self, client, fake_getui):
        """E2EE 边界硬断言：序列化后的出站请求不含任何业务字段值。"""
        client.post("/_matrix/push/v1/notify", json=matrix_notify(
            event_type="m.call.invite", pushkey="cid-9"))
        wire = json.dumps(fake_getui.push_calls[0]["body"], ensure_ascii=False)
        for forbidden in [
            "secret-event-id",
            "secret-room",
            "secret-sender",
            "秘密发送者",
            "秘密消息正文",
            "秘密群名称",
            "event_id",
            "room_id",
            "sender",
            "content",
        ]:
            assert forbidden not in wire, f"出站载荷泄露业务内容: {forbidden}"

    def test_invalid_body_rejected(self, client):
        assert client.post("/_matrix/push/v1/notify", json={"bad": 1}).status_code == 400
        assert client.post("/_matrix/push/v1/notify", json={}).status_code == 400

    def test_healthz(self, client):
        assert client.get("/healthz").status_code == 200


class TestRateLimit:
    def test_burst_same_cid_is_collapsed(self):
        class _Counting:
            def __init__(self):
                self.sent = []

            def push(self, cid, kind):
                self.sent.append((cid, kind))
                return True

        from app.rate_limit import CidRateLimiter
        limiter = CidRateLimiter(min_interval_ms=60_000)
        counter = _Counting()
        from app.main import deliver_sanitized
        deliver_sanitized(counter, limiter, {"kind": "message", "cids": ["cid-1"]})
        deliver_sanitized(counter, limiter, {"kind": "message", "cids": ["cid-1"]})
        deliver_sanitized(counter, limiter, {"kind": "message", "cids": ["cid-1"]})
        assert len(counter.sent) == 1, "风暴必须收敛为一次实际下发"


class TestGetuiClient:
    def test_sign_format_is_sha256_hex_of_appkey_timestamp_secret(self):
        from app.getui_client import compute_sign
        sign = compute_sign(appkey="k", timestamp="123", secret="s")
        assert sign == hashlib.sha256(b"k123s").hexdigest()

    def test_token_cached_until_expiry(self, fake_getui):
        from app.getui_client import GetuiRestClient
        client = GetuiRestClient(
            base_url="https://restapi.getui.com",
            app_id="test-app-id",
            app_key="test-app-key",
            sign_secret="test-sign-secret",
            http_client=httpx.Client(transport=httpx.MockTransport(fake_getui.handler)),
        )
        client.auth_token(1_000)
        client.auth_token(2_000)
        assert len(fake_getui.auth_calls) == 1, "token 未过期必须复用"
        body = fake_getui.auth_calls[0]
        assert set(body.keys()) == {"sign", "timestamp", "appkey"}
