"""个推 REST v2 客户端（服务端密钥只在本模块使用，绝不写日志）。

鉴权：POST {base}/v2/{appId}/auth
  sign = sha256_hex(appkey + timestamp + secret)（13 位毫秒时间戳）
  → {code:0, data:{token, expire_time}}（token 有效期 1 天）
推送：POST {base}/v2/{appId}/push/single/cid（header: token）
  出站载荷白名单见 build_push_body —— 严禁携带任何 Matrix 业务字段。
"""
import hashlib
import json
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
    body: dict[str, Any] = {
        "request_id": f"cf{time.time_ns()}{secrets.token_hex(4)}"[:32],
        "settings": {"ttl": ttl_ms},
        "audience": {"cid": [cid]},
    }
    if kind == "call":
        # 来电：透传唤醒指令（原生 CallForegroundService → CallStyle 锁屏
        # 来电）。载荷仅 type/video，无任何业务内容（E2EE 红线；video 细分
        # 由实际信令定，通知一律语音样式）。
        body["push_message"] = {
            "transmission": json.dumps(
                {"type": "call", "video": False}, ensure_ascii=False
            )
        }
        return body
    # 消息：通知通道（通用文案）+ 离线厂商通道——同样只有通用文案。
    body["push_message"] = {"notification": notification}
    body["push_channel"] = {
        "android": {"ups": {"notification": dict(notification)}},
    }
    return body


class GetuiPushError(Exception):
    """推送失败（含不可恢复的业务错误码）。"""

    # 个推明确表示该 CID 永久失效的业务码（可安全进 Matrix rejected；
    # Synapse 会删除 pusher，客户端下次登录重新注册）。
    PERMANENT_CODES = frozenset({
        10009,  # token 无效
        20101,  # cid 为空
        20102,  # cid 不存在/格式非法
        20103,  # cid 已注销
        20104,  # cid 已失效
        20105,  # cid 与 AppID 不匹配
    })

    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code

    @property
    def is_permanent(self) -> bool:
        """个推明确表示 CID 永久不可用（进 rejected 让 Synapse 删 pusher）。

        其他码（鉴权失败/限流/参数/服务繁忙）和运输层异常是临时的：
        绝不能进 rejected，否则一次服务端故障让用户永远收不到推送。
        """
        return self.code is not None and self.code in self.PERMANENT_CODES


class GetuiTransientError(Exception):
    """临时错误（网络/超时/5xx/DNS/鉴权失败）：不进 rejected，
    Synapse 会重试，pusher 不受影响。"""


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
        永久 CID 失效 → GetuiPushError(is_permanent=True)；
        网络/5xx/超时 → GetuiTransientError（绝不进 Matrix rejected）。
        """
        body = build_push_body(cid, kind, ttl_ms)
        for attempt in (1, 2):
            token = self._current_token(int(time.time() * 1000))
            try:
                response = self._http.post(
                    f"{self._base}/v2/{self._app_id}/push/single/cid",
                    json=body,
                    headers={"token": token},
                )
            except httpx.HTTPError as error:
                raise GetuiTransientError(
                    f"transport error: {type(error).__name__}"
                ) from error
            if response.status_code != 200:
                # 优先解析个推业务错误码（CID 无效等也是非 200 + code）。
                try:
                    error_payload = response.json()
                    code = error_payload.get("code")
                    if code is not None:
                        raise GetuiPushError(
                            f"getui push failed code={code}", code=int(code)
                        )
                except GetuiPushError:
                    raise
                except Exception:
                    raise GetuiTransientError(
                        f"http {response.status_code}"
                    ) from None
            payload = response.json()
            code = payload.get("code")
            if code == 0:
                status = (payload.get("data") or {}).get("status", "")
                return str(status)
            if code == 10001 and attempt == 1:
                self._token = None  # token 失效，刷新后重试
                continue
            raise GetuiPushError(f"getui push failed code={code}", code=int(code))
        raise GetuiPushError("getui push retry exhausted")
