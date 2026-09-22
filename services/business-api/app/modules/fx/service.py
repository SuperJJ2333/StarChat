"""ADR-0076 决策5：USD/CNY 参考汇率服务（apihz 单源）。

硬约束（用户 2026-09-21 需求书）：
- 仅按需访问上游：只有用户请求且缓存过期/缺失时才调用；无后台定时拉取。
- 缓存持久化 60 分钟，从本地成功获取时间起算；服务重启不丢失有效期。
- 并发合并：行级认领（条件 UPDATE）+ 认领后二次检查，同一过期窗口
  只允许一次上游调用，不产生请求风暴。
- 优先读响应 `rate` 字段；money=10 时 `result` 是 10 美元换算结果，
  绝不当作单位汇率，仅在缺 rate 时按 result/money 推导并校验。
- 失败不写假汇率（1/0）、不清最后有效报价；失败时间持久化为共享退避，
  同一 60 分钟窗口内不再自动重试；过期报价继续展示必须标注 stale。
- 1 USDT 暂按 1 USD 估算；展示方须标注"参考估算，最终以客服结算为准"。
- HTTPS 证书校验保留；URL/异常一律脱敏 id/key。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal, DecimalException, InvalidOperation, ROUND_HALF_UP
import time
import logging
import re

from sqlalchemy import select, update, or_
from sqlalchemy.exc import IntegrityError
from uuid import uuid4

from app.core.errors import AppError
from app.modules.fx.models import FxRate

PAIR = "USD/CNY"
RATE_PLACES = Decimal("0.000001")
DEFAULT_TTL_SECONDS = 3600
CLAIM_TIMEOUT_SECONDS = 20
HTTP_TIMEOUT_SECONDS = 6.0
RATE_SANITY_MAX = Decimal("1000")  # USD/CNY 合理上界；防御性解析护栏
DISCLAIMER = "参考估算，最终以客服结算为准"


class _CredentialQueryFilter(logging.Filter):
    def filter(self, record):
        message = record.getMessage()
        redacted = re.sub(r"(?i)([?&](?:id|key)=)[^&\s\"']+", r"\1***", message)
        if redacted != message:
            record.msg, record.args = redacted, ()
        return True


_HTTP_CREDENTIAL_FILTER = _CredentialQueryFilter()


def _utc(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def masked_url(url: str) -> str:
    """脱敏：id/key 只留长度线索，绝不出现在日志/错误里。"""
    from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
    parts = urlsplit(url)
    query = [(k, "***" if k.lower() in {"id", "key"} else v)
             for k, v in parse_qsl(parts.query, keep_blank_values=True)]
    return urlunsplit(parts._replace(query=urlencode(query)))


class FxService:
    def __init__(
        self,
        session_factory,
        *,
        api_id: str | None,
        api_key: str | None,
        api_url: str = "https://cn.apihz.cn/api/jinrong/huilv.php",
        ttl_seconds: int = DEFAULT_TTL_SECONDS,
        http_get=None,
        now=None,
        instance_id: str = "business-api",
        upstream_money: str = "10",
    ):
        self.factory = session_factory
        self.api_url = api_url
        self.api_id = api_id
        self.api_key = api_key
        self.ttl_seconds = int(ttl_seconds)
        self.http_get = http_get or _default_http_get
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.instance_id = uuid4().hex
        self.upstream_money = upstream_money
        if self.ttl_seconds <= 0:
            raise ValueError("fx ttl must be positive")

    # ------------------------------------------------------------------ public
    def get_rate_snapshot(self, *, actor_id: str) -> dict:
        """返回当前可展示快照；过期时按需刷新；失败退避内返回过期参考。"""
        now = _utc(self.now())
        fresh = self._fresh_row(now)
        if fresh is not None:
            return self._snapshot(fresh, stale=False)
        row = self._row()
        if row is not None and row["last_attempt_at"] is not None:
            age = (now - _utc(row["last_attempt_at"])).total_seconds()
            if 0 <= age < self.ttl_seconds:
                # 失败共享退避：本窗口内不再访问上游，过期报价标注 stale。
                if row["rate"] is not None:
                    return self._snapshot(row, stale=True)
                raise AppError(code="FX_UNAVAILABLE", message="汇率暂时不可用", status_code=503)
        if self.api_id is None or self.api_key is None or not str(self.api_id).strip() or not str(self.api_key).strip():
            self._record_failure("CONFIG_MISSING", now)
            if row is not None and row["rate"] is not None:
                return self._snapshot(row, stale=True)
            raise AppError(code="FX_NOT_CONFIGURED", message="汇率服务未配置", status_code=503)
        claimed = self._claim(now)
        if not claimed:
            # 其他实例正在取：短暂等待后二次检查，绝不并发打上游。
            _sleep(0.4)
            now2 = _utc(self.now())
            fresh2 = self._fresh_row(now2)
            if fresh2 is not None:
                return self._snapshot(fresh2, stale=False)
            row2 = self._row()
            if row2 is not None and row2["rate"] is not None:
                return self._snapshot(row2, stale=True)
            raise AppError(code="FX_UNAVAILABLE", message="汇率暂时不可用", status_code=503)
        try:
            payload = self.http_get(self._request_url(), HTTP_TIMEOUT_SECONDS)
        except Exception:
            self._record_failure("UPSTREAM_ERROR", _utc(self.now()), claim_token=claimed)
            row3 = self._row()
            if row3 is not None and row3["rate"] is not None:
                return self._snapshot(row3, stale=True)
            raise AppError(code="FX_UNAVAILABLE", message="汇率暂时不可用", status_code=503) from None
        try:
            rate, uptime = _parse_upstream(payload, money=self.upstream_money)
        except (ValueError, DecimalException):
            self._record_failure("UPSTREAM_PAYLOAD_INVALID", _utc(self.now()), claim_token=claimed)
            row3 = self._row()
            if row3 is not None and row3["rate"] is not None:
                return self._snapshot(row3, stale=True)
            raise AppError(code="FX_UNAVAILABLE", message="汇率暂时不可用", status_code=503) from None
        return self._record_success(rate, uptime, claim_token=claimed)

    # ----------------------------------------------------------------- private
    def _row(self):
        """返回可脱离会话使用的快照 dict（避免 detached 实例属性访问）。"""
        with self.factory() as session:
            row = session.scalar(select(FxRate).where(FxRate.pair == PAIR))
            if row is None:
                return None
            return {
                "rate": Decimal(row.rate) if row.rate is not None else None,
                "fetched_at": row.fetched_at,
                "expires_at": row.expires_at,
                "upstream_uptime": row.upstream_uptime,
                "last_attempt_at": row.last_attempt_at,
            }

    def _fresh_row(self, now):
        row = self._row()
        if row is None or row["rate"] is None or row["expires_at"] is None:
            return None
        return row if _utc(row["expires_at"]) > now else None

    def _claim(self, now) -> str | None:
        """行级认领：无行先建占位行；先抢 idle；超时认领用"读后原值相等"
        条件更新（SQLite naive / PG aware 通用，不在 SQL 侧做时间运算）。"""
        claim_token = uuid4().hex
        with self.factory.begin() as session:
            if session.get(FxRate, PAIR) is None:
                try:
                    with session.begin_nested():
                        session.add(FxRate(pair=PAIR, fetch_state="idle"))
                        session.flush()
                except IntegrityError:
                    pass  # Another cold request created the single shared row.
            eligible = (
                or_(FxRate.expires_at.is_(None), FxRate.expires_at <= now),
                or_(FxRate.last_attempt_at.is_(None),
                    FxRate.last_attempt_at <= now - timedelta(seconds=self.ttl_seconds)),
            )
            idle = session.execute(
                update(FxRate)
                .where(FxRate.pair == PAIR, FxRate.fetch_state == "idle", *eligible)
                .values(fetch_state="fetching", fetch_claimed_at=now, fetch_claimed_by=claim_token)
            )
            if idle.rowcount == 1:
                return claim_token
            row = session.execute(
                select(FxRate.pair, FxRate.fetch_state, FxRate.fetch_claimed_at, FxRate.fetch_claimed_by).where(FxRate.pair == PAIR)
            ).first()
            if row is None or row.fetch_state != "fetching" or row.fetch_claimed_at is None:
                return False
            if not (now - _utc(row.fetch_claimed_at)).total_seconds() > CLAIM_TIMEOUT_SECONDS:
                return False
            expired = session.execute(
                update(FxRate)
                .where(
                    FxRate.pair == PAIR,
                    FxRate.fetch_state == "fetching",
                    FxRate.fetch_claimed_at == row.fetch_claimed_at,
                    FxRate.fetch_claimed_by == row.fetch_claimed_by,
                    *eligible,
                )
                .values(fetch_state="fetching", fetch_claimed_at=now, fetch_claimed_by=claim_token)
            )
            return claim_token if expired.rowcount == 1 else None

    def _record_success(self, rate: Decimal, uptime: str | None, *, claim_token: str) -> dict:
        from sqlalchemy import update

        now = _utc(self.now())
        with self.factory.begin() as session:
            session.execute(
                update(FxRate)
                .where(FxRate.pair == PAIR, FxRate.fetch_claimed_by == claim_token,
                       FxRate.fetch_state == "fetching")
                .values(
                    rate=rate,
                    fetched_at=now,
                    expires_at=now + timedelta(seconds=self.ttl_seconds),
                    upstream_uptime=uptime,
                    last_error_code=None,
                    last_attempt_at=now,
                    fetch_state="idle",
                    fetch_claimed_at=None,
                    fetch_claimed_by=None,
                )
            )
        row = self._row()
        if row is None or row["rate"] is None:
            raise AppError(code="FX_UNAVAILABLE", message="汇率暂时不可用", status_code=503)
        return self._snapshot(row, stale=row["expires_at"] is None or _utc(row["expires_at"]) <= now)

    def _record_failure(self, error_code: str, now: datetime, *, claim_token=None):
        from sqlalchemy import update

        with self.factory.begin() as session:
            existing = session.scalar(select(FxRate.pair).where(FxRate.pair == PAIR))
            if existing is None:
                try:
                    with session.begin_nested():
                        session.add(FxRate(pair=PAIR, fetch_state="idle", last_attempt_at=now, last_error_code=error_code))
                        session.flush()
                except IntegrityError:
                    pass
            else:
                session.execute(
                    update(FxRate)
                    .where(FxRate.pair == PAIR,
                           (FxRate.fetch_claimed_by == claim_token) if claim_token else FxRate.fetch_state == "idle")
                    .values(last_attempt_at=now, last_error_code=error_code, fetch_state="idle",
                            fetch_claimed_by=None, fetch_claimed_at=None)
                )

    @staticmethod
    def _snapshot(row, *, stale: bool) -> dict:
        return {
            "pair": PAIR,
            "rate": row["rate"],
            "fetched_at": row["fetched_at"],
            "expires_at": row["expires_at"],
            "stale": stale,
            "upstream_uptime": row["upstream_uptime"],
            "pricing_basis": "1 USDT ≈ 1 USD（参考）",
            "disclaimer": DISCLAIMER,
        }

    def _request_url(self) -> str:
        from urllib.parse import urlencode

        query = urlencode({"from": "USD", "to": "CNY", "money": self.upstream_money, "id": self.api_id, "key": self.api_key})
        return f"{self.api_url}?{query}"


def _sleep(seconds: float):
    # 同步路径：API 端点为 sync def（FastAPI 线程池执行），短等待不阻塞事件循环。
    time.sleep(seconds)


def _default_http_get(url: str, timeout: float):
    """生产适配器：同步 httpx，保留 HTTPS 证书校验；异常一律向上抛。"""
    import httpx
    # httpx logs complete request URLs at INFO before returning a response.
    # Redact at the originating logger, before any handler sees the record.
    logging.getLogger("httpx").addFilter(_HTTP_CREDENTIAL_FILTER)
    with httpx.Client(timeout=timeout, verify=True, follow_redirects=False) as client:
        response = client.get(url)
        if response.status_code != 200:
            raise RuntimeError(f"fx upstream status {response.status_code}")
        return response.json()


def _parse_upstream(payload, *, money: str) -> tuple[Decimal, str | None]:
    """校验成功码/方向/正数汇率/结构；优先 rate 字段，缺 rate 才允许 result/money。"""
    if not isinstance(payload, dict):
        raise ValueError("payload not an object")
    code = payload.get("code", 200)
    try:
        code_ok = int(str(code)) == 200
    except (TypeError, ValueError):
        code_ok = False
    if not code_ok:
        raise ValueError("upstream code not success")
    pair_from = str(payload.get("from", "USD")).upper()
    pair_to = str(payload.get("to", "CNY")).upper()
    if pair_from != "USD" or pair_to != "CNY":
        raise ValueError("wrong pair direction")
    rate = _positive_decimal(payload.get("rate"))
    if "rate" in payload and rate is None:
        raise ValueError("invalid explicit rate")
    if "rate" not in payload:
        try:
            result = _positive_decimal(payload.get("result"))
            divisor = _positive_decimal(money)
        except (InvalidOperation, ValueError):
            raise ValueError("result without money divisor") from None
        if result is None or divisor is None:
            raise ValueError("missing rate and result")
        if "money" in payload and _positive_decimal(payload["money"]) != divisor:
            raise ValueError("upstream amount does not match requested amount")
        rate = result / divisor
    if rate >= RATE_SANITY_MAX:
        raise ValueError("rate out of sane range")
    rate = rate.quantize(RATE_PLACES, rounding=ROUND_HALF_UP)
    if rate <= 0:
        raise ValueError("rate below supported precision")
    return rate, (
        str(payload.get("uptime"))[:64] if payload.get("uptime") is not None else None
    )


def _positive_decimal(value) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    return number if number.is_finite() and number > 0 else None
