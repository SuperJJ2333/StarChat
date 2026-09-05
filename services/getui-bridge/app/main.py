"""getui-bridge：Matrix Push Gateway 协议 → 个推 v2。

- POST /_matrix/push/v1/notify：Synapse 入站（脱敏在 app.notify 完成）。
- GET /healthz：容器健康检查。
日志红线：绝不记录入站业务内容、CID 全量、密钥。
"""
import asyncio
import logging
from typing import Any

import anyio.to_thread
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .config import BridgeSettings
from .getui_client import (
    GetuiPushError,
    GetuiRestClient,
    GetuiTransientError,
)
from .notify import sanitize_notification
from .rate_limit import CidRateLimiter

logger = logging.getLogger("getui-bridge")
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s")

# C01：供应商请求有界并发（线程池 + 信号量），不再按 CID 串行阻塞事件循环。
MAX_CONCURRENT_PUSHES = 4


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

        # 单 CID 投递：同步 httpx 调用经线程池卸载（C01），并发受信号量
        # 约束。结果：True=供应商已受理；False=临时失败（限频资格已回滚，
        # 由 503 触发协议重试）；None=限频窗口内收敛跳过（风暴去重）。
        async def _deliver_one(cid: str, semaphore: asyncio.Semaphore) -> bool | None:
            if not limiter.allow(cid, sanitized.kind):
                # 窗口内重复风暴：静默收敛（不视为设备失效，也不重试）。
                return None
            try:
                async with semaphore:
                    await anyio.to_thread.run_sync(
                        lambda cid=cid: client.push_cid(cid, sanitized.kind, config.notify_ttl_ms)
                    )
                return True
            except GetuiPushError as error:
                if error.is_permanent:
                    # 仅个推明确表示该 CID 永久失效才进 rejected——Synapse
                    # 据此删除 pusher，客户端下次登录重新注册。
                    logger.info(
                        "push permanently rejected kind=%s code=%s",
                        sanitized.kind,
                        error.code,
                    )
                    raise _PermanentRejection(cid) from error
                # 临时业务错误：回滚限频资格，交给协议重试。
                limiter.release(cid, sanitized.kind)
                logger.warning(
                    "push transient (non-permanent) kind=%s code=%s",
                    sanitized.kind,
                    error.code,
                )
                return False
            except GetuiTransientError as error:
                # 网络/超时/5xx：绝不进 rejected；回滚限频资格后由 503
                # 触发 Synapse 重试（一次服务器故障不能让用户收不到推送）。
                limiter.release(cid, sanitized.kind)
                logger.warning("push transport error kind=%s err=%s", sanitized.kind, error)
                return False
            except Exception as error:  # noqa: BLE001 —— 未预期异常同临时处理
                limiter.release(cid, sanitized.kind)
                logger.warning(
                    "push unexpected error kind=%s err_type=%s",
                    sanitized.kind,
                    type(error).__name__,
                )
                return False

        semaphore = asyncio.Semaphore(MAX_CONCURRENT_PUSHES)
        try:
            results = await asyncio.gather(
                *(_deliver_one(cid, semaphore) for cid in sanitized.cids),
                return_exceptions=True,
            )
        except Exception:  # pragma: no cover —— gather(return_exceptions) 不抛
            results = []

        rejected = [
            outcome.cid
            for outcome in results
            if isinstance(outcome, _PermanentRejection)
        ]
        transient_failures = any(outcome is False for outcome in results)
        if transient_failures:
            # P01：存在临时失败 → 503 让 Synapse 按协议重试本通知；
            # 已成功的 CID 保留限频窗口（重试时被去重，不重复提醒），
            # 失败的 CID 已回滚资格（重试会真正重发）。仅永久失效设备
            # 进入 rejected（与重试状态码互不干扰：Synapse 对 503 响应
            # 不处理 rejected 列表，pusher 不受影响）。
            return JSONResponse({"rejected": rejected}, status_code=503)
        return JSONResponse({"rejected": rejected} if rejected else {})

    return app


class _PermanentRejection(Exception):
    """CID 永久失效（转为 rejected 列表）。"""

    def __init__(self, cid: str) -> None:
        super().__init__(cid)
        self.cid = cid


def deliver_sanitized(sender, limiter, spec: dict) -> None:
    """限频投递（独立函数便于单测：风暴收敛）。"""
    for cid in spec["cids"]:
        if limiter.allow(cid):
            sender.push(cid, spec["kind"])


app = create_app()
