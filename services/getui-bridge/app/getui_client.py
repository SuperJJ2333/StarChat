"""个推 REST v2 客户端（服务端密钥只在本模块使用，绝不写日志）。

鉴权：POST {base}/v2/{appId}/auth
  sign = sha256_hex(appkey + timestamp + secret)（13 位毫秒时间戳）
  → {code:0, data:{token, expire_time}}（token 有效期 1 天）
推送：POST {base}/v2/{appId}/push/single/cid（header: token）
  出站载荷白名单见 build_push_body —— 严禁携带任何 Matrix 业务字段。
"""
import hashlib
import secrets
import time
from typing import Any

import httpx


def compute_sign(appkey: str, timestamp: str, secret: str) -> str:
    return hashlib.sha256(f"{appkey}{timestamp}{secret}".encode()).hexdigest()


GENERIC_TITLE = "畅聊"
GENERIC_BODY = {"message": "您有一条新消息", "call": "您有一个来电"}


def build_push_body(cid: str, kind: str, ttl_ms: int) -> dict[str, Any]:
    """构造出站请求体——E2EE 边界出站白名单（测试逐键断言）。

    保留的信息恰好是任务允许的四类：设备映射（audience.cid）、
    随机通知 ID（notify_id）、消息类型（通用文案二选一）、有效期（ttl）。
    """
    notify_id = secrets.randbelow(2_147_483_647)
    body = GENERIC_BODY.get(kind, GENERIC_BODY["message"])
    notification = {
        "title": GENERIC_TITLE,
        "body": body,
        "click_type": "startapp",
        "notify_id": notify_id,
    }
    return {
        "request_id": f"cf{time.time_ns()}{secrets.token_hex(4)}"[:32],
        "settings": {"ttl": ttl_ms},
        "audience": {"cid": [cid]},
        # 在线个推通道
        "push_message": {"notification": notification},
        # 离线厂商通道（App 被杀时的送达路径）——同样只有通用文案。
        "push_channel": {
            "android": {"ups": {"notification": dict(notification)}},
        },
    }


class GetuiPushError(Exception):
    """推送失败（含不可恢复的业务错误码）。"""


class GetuiRestClient:
    def __init__(
        self,
        *,
        base_url: str,
        app_id: str,
        app_key: str,
        sign_secret: str,
        http_client: httpx.Client,
        token_ttl_safety_ms: int = 60_000,
    ):
        self._base = base_url.rstrip("/")
        self._app_id = app_id
        self._app_key = app_key
        self._sign_secret = sign_secret
        self._http = http_client
        self._token_ttl_safety_ms = token_ttl_safety_ms
        self._token: str | None = None
        self._token_expire_ms: int = 0

    def _fetch_token(self) -> str:
        timestamp = str(int(time.time() * 1000))
        response = self._http.post(
            f"{self._base}/v2/{self._app_id}/auth",
            json={
                "sign": compute_sign(self._app_key, timestamp, self._sign_secret),
                "timestamp": timestamp,
                "appkey": self._app_key,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if payload.get("code") != 0:
            raise GetuiPushError(f"getui auth failed code={payload.get('code')}")
        data = payload.get("data") or {}
        token = data.get("token")
        if not isinstance(token, str) or not token:
            raise GetuiPushError("getui auth returned no token")
        self._token = token
        expire = data.get("expire_time")
        self._token_expire_ms = (
            int(expire) if isinstance(expire, int) else int(time.time() * 1000) + 86_400_000
        )
        return token

    def _current_token(self, now_ms: int) -> str:
        if (
            self._token is not None
            and now_ms + self._token_ttl_safety_ms < self._token_expire_ms
        ):
            return self._token
        return self._fetch_token()

    def auth_token(self, now_ms: int) -> str:
        """带缓存的 token 获取（未过期复用；供测试注入当前时间）。"""
        return self._current_token(now_ms)

    def push_cid(self, cid: str, kind: str, ttl_ms: int) -> str:
        """单 CID 推送；返回个推 status（successed_online/offline/…）。

        token 失效（code=10001）自动刷新重试一次。
        """
        body = build_push_body(cid, kind, ttl_ms)
        for attempt in (1, 2):
            token = self._current_token(int(time.time() * 1000))
            response = self._http.post(
                f"{self._base}/v2/{self._app_id}/push/single/cid",
                json=body,
                headers={"token": token},
            )
            response.raise_for_status()
            payload = response.json()
            code = payload.get("code")
            if code == 0:
                status = (payload.get("data") or {}).get("status", "")
                return str(status)
            if code == 10001 and attempt == 1:
                self._token = None  # token 失效，刷新后重试
                continue
            raise GetuiPushError(f"getui push failed code={code}")
        raise GetuiPushError("getui push retry exhausted")
