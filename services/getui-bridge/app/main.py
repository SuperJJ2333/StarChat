"""getui-bridge：Matrix Push Gateway 协议 → 个推 v2。

- POST /_matrix/push/v1/notify：Synapse 入口（脱敏在 app.notify 完成）。
- GET /healthz：容器健康检查。
日志红线：绝不记录入站业务内容、CID 全量、密钥。
"""
import logging
from typing import Any

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .config import BridgeSettings
from .getui_client import GetuiPushError, GetuiRestClient
from .notify import sanitize_notification
from .rate_limit import CidRateLimiter

logger = logging.getLogger("getui-bridge")
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")


def create_app(settings: BridgeSettings | None = None, http_client: httpx.Client | None = None) -> FastAPI:
    app = FastAPI(title="chatflow-getui-bridge", docs_url=None, redoc_url=None, openapi_url=None)
    config = settings or BridgeSettings()
    client = GetuiRestClient(
        base_url=config.getui_rest_base,
        app_id=config.getui_app_id,
        app_key=config.getui_app_key,
        sign_secret=config.getui_sign_secret,
        http_client=http_client
        or httpx.Client(timeout=httpx.Timeout(10.0)),
    )
    limiter = CidRateLimiter(min_interval_ms=config.rate_limit_ms)

    @app.get("/healthz")
    def healthz() -> dict[str, Any]:
        return {"ok": True}

    # 两个等价入口：标准网关路径（本地/测试）与 nginx 转发的
    # /getui/ 专属前缀（生产，客户端 data.url 使用该形态）。
    @app.post("/_matrix/push/v1/notify")
    @app.post("/_matrix/push/v1/getui/notify")
    async def notify(request: Request) -> JSONResponse:
        try:
            body = await request.json()
        except Exception:
            return JSONResponse({"error": "invalid body"}, status_code=400)
        if not isinstance(body, dict):
            return JSONResponse({"error": "invalid body"}, status_code=400)
        sanitized = sanitize_notification(body, config.matrix_app_id)
        if sanitized is None:
            # 无目标设备/app_id 不匹配/结构非法：按网关协议 200 空回。
            if "notification" not in body:
                return JSONResponse({"error": "invalid body"}, status_code=400)
            return JSONResponse({})

        rejected: list[str] = []
        for cid in sanitized.cids:
            if not limiter.allow(cid):
                # 窗口内重复风暴：静默收敛（不视为设备失效）。
                continue
            try:
                client.push_cid(cid, sanitized.kind, config.notify_ttl_ms)
            except GetuiPushError as error:
                # 设备不可达/鉴权失败等：回 rejected 让 homeserver 记账。
                # 只记错误类别与文案（个推返回的 msg 不含业务内容）。
                logger.info("push rejected kind=%s err=%s", sanitized.kind, error)
                rejected.append(cid)
            except Exception as error:
                # 上游网络/HTTP 异常同样收敛为 rejected：网关绝不因
                # 个推侧故障向 homeserver 抛 5xx（会触发其重试风暴）。
                logger.warning(
                    "push transport error kind=%s err_type=%s",
                    sanitized.kind,
                    type(error).__name__,
                )
                rejected.append(cid)
        return JSONResponse({"rejected": rejected} if rejected else {})

    return app


def deliver_sanitized(sender, limiter, spec: dict) -> None:
    """限频投递（独立函数便于单测：风暴收敛）。"""
    for cid in spec["cids"]:
        if limiter.allow(cid):
            sender.push(cid, spec["kind"])


app = create_app()
