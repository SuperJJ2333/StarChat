"""Immutable observer facts and append-only coverage verdicts."""
from datetime import datetime

from sqlalchemy import BigInteger, CheckConstraint, DateTime, JSON, String, UniqueConstraint, event, inspect
from sqlalchemy.orm import Mapped, mapped_column

from app.core.database import Base


class WalletFundingCoverageEvent(Base):
    __tablename__ = 'wallet_funding_coverage_events'
    __table_args__ = (
        UniqueConstraint('source_identity', 'source_rowid', name='uq_wallet_coverage_source_row'),
        UniqueConstraint('source_identity', 'txid', 'log_index', name='uq_wallet_coverage_source_log'),
        CheckConstraint("status IN ('PENDING','VERIFIED','CONFLICT')", name='ck_wallet_coverage_status'),
        CheckConstraint('source_rowid > 0 AND log_index >= 0 AND block_number >= 0 AND timestamp_ms >= 0',
                        name='ck_wallet_coverage_numbers'),
        CheckConstraint("(status = 'PENDING' AND proof IS NULL AND verified_at IS NULL AND conflict_at IS NULL) OR "
                        "(status = 'VERIFIED' AND proof IS NOT NULL AND verified_at IS NOT NULL AND conflict_at IS NULL) OR "
                        "(status = 'CONFLICT' AND conflict_at IS NOT NULL AND "
                        "((proof IS NULL AND verified_at IS NULL) OR (proof IS NOT NULL AND verified_at IS NOT NULL)))",
                        name='ck_wallet_coverage_shape'),
    )
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    source_identity: Mapped[str] = mapped_column(String(64), nullable=False)
    source_rowid: Mapped[int] = mapped_column(BigInteger, nullable=False)
    txid: Mapped[str] = mapped_column(String(64), nullable=False)
    log_index: Mapped[int] = mapped_column(BigInteger, nullable=False)
    amount_units: Mapped[str] = mapped_column(String(100), nullable=False)
    from_address: Mapped[str] = mapped_column(String(34), nullable=False)
    to_address: Mapped[str] = mapped_column(String(34), nullable=False)
    block_number: Mapped[int] = mapped_column(BigInteger, nullable=False)
    timestamp_ms: Mapped[int] = mapped_column(BigInteger, nullable=False)
    facts_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    proof: Mapped[dict | None] = mapped_column(JSON(none_as_null=True))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    conflict_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


@event.listens_for(WalletFundingCoverageEvent, 'before_update')
def immutable_coverage(mapper, connection, target):
    state = inspect(target)
    mutable = {'status', 'proof', 'verified_at', 'conflict_at'}
    if any(state.attrs[c.name].history.has_changes() for c in target.__table__.columns if c.name not in mutable):
        raise ValueError('immutable funding coverage facts')
    history = state.attrs.status.history
    old = history.deleted[0] if history.deleted else target.status
    if old == 'CONFLICT' or (old == 'VERIFIED' and target.status != 'CONFLICT'):
        raise ValueError('immutable funding coverage verdict')
    for name in ('proof', 'verified_at', 'conflict_at'):
        h = state.attrs[name].history
        if h.has_changes() and h.deleted and h.deleted[0] is not None:
            raise ValueError('immutable funding coverage proof')
    if target.status == 'VERIFIED' and (not target.proof or target.verified_at is None):
        raise ValueError('funding coverage proof required')
    if target.status == 'CONFLICT' and target.conflict_at is None:
        raise ValueError('funding coverage conflict time required')


@event.listens_for(WalletFundingCoverageEvent, 'before_delete')
def immutable_delete(mapper, connection, target):
    raise ValueError('immutable funding coverage record')
