"""ADR-0076：FX 参考汇率持久缓存。

一行一币对。`rate` 可空：行可以在首次成功获取前被认领写入（并发冷启动
合并需要行存在才能行级认领）。`expires_at = fetched_at + TTL(60min)`，
从本地成功获取时间起算；`upstream_uptime` 独立保存供应商可用性；
`last_attempt_at` 持久化失败退避（同一 60 分钟窗口不再自动重试上游）。
"""
from datetime import datetime
from decimal import Decimal

from sqlalchemy import DateTime, Numeric, String
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class FxRate(Base):
    __tablename__ = "fx_rates"
    pair: Mapped[str] = mapped_column(String(16), primary_key=True)  # 'USD/CNY'
    rate: Mapped[Decimal | None] = mapped_column(Numeric(20, 6), nullable=True)
    fetched_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    upstream_uptime: Mapped[str | None] = mapped_column(String(64), nullable=True)
    last_attempt_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    last_error_code: Mapped[str | None] = mapped_column(String(64), nullable=True)
    fetch_state: Mapped[str] = mapped_column(String(16), nullable=False, default="idle")
    fetch_claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    fetch_claimed_by: Mapped[str | None] = mapped_column(String(64), nullable=True)
