"""Private-wallet ownership and versioned activation boundaries (no money state)."""
from datetime import datetime
from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, Index, JSON, String, Text, UniqueConstraint, text
from sqlalchemy.orm import Mapped, mapped_column
from app.core.database import Base


class WalletAddressOwner(Base):
    __tablename__ = 'wallet_address_owners'
    address: Mapped[str] = mapped_column(String(34), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class WalletBindingState(Base):
    __tablename__ = 'wallet_binding_states'
    user_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    version: Mapped[int] = mapped_column(nullable=False, default=0)
    active_binding_id: Mapped[str | None] = mapped_column(String(36), unique=True)
    pending_binding_id: Mapped[str | None] = mapped_column(String(36), unique=True)
    last_rebind_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WalletBinding(Base):
    __tablename__ = 'wallet_bindings'
    __table_args__ = (UniqueConstraint('user_id', 'version', name='uq_wallet_binding_version'),
        Index('uq_wallet_binding_active', 'user_id', unique=True, postgresql_where=text("status = 'ACTIVE'"), sqlite_where=text("status = 'ACTIVE'")),
        Index('uq_wallet_binding_pending', 'user_id', unique=True, postgresql_where=text("status = 'PENDING'"), sqlite_where=text("status = 'PENDING'")),
        CheckConstraint("status IN ('PENDING', 'ACTIVE', 'RETIRED')", name='ck_wallet_binding_status'),
        CheckConstraint("(status = 'PENDING' AND activated_at IS NULL AND effective_from_block IS NULL AND effective_to_block IS NULL AND barrier_height IS NULL AND barrier_block_id IS NULL AND barrier_source_ids IS NULL AND barrier_observed_at IS NULL) OR (status IN ('ACTIVE', 'RETIRED') AND activated_at IS NOT NULL AND effective_from_block IS NOT NULL AND barrier_height IS NOT NULL AND barrier_height >= 0 AND effective_from_block = barrier_height + 1 AND barrier_block_id IS NOT NULL AND barrier_source_ids IS NOT NULL AND barrier_observed_at IS NOT NULL AND ((status = 'ACTIVE' AND effective_to_block IS NULL) OR (status = 'RETIRED' AND effective_to_block IS NOT NULL)))", name='ck_wallet_binding_evidence'),
        CheckConstraint('effective_to_block IS NULL OR effective_to_block > effective_from_block', name='ck_wallet_binding_interval'))
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    address: Mapped[str] = mapped_column(ForeignKey('wallet_address_owners.address'), nullable=False)
    version: Mapped[int] = mapped_column(nullable=False)
    status: Mapped[str] = mapped_column(String(16), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    activated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    effective_from_block: Mapped[int | None] = mapped_column(BigInteger)
    effective_to_block: Mapped[int | None] = mapped_column(BigInteger)
    barrier_height: Mapped[int | None] = mapped_column(BigInteger)
    barrier_block_id: Mapped[str | None] = mapped_column(String(64))
    barrier_source_ids: Mapped[list[str] | None] = mapped_column(JSON(none_as_null=True))
    barrier_observed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    barrier_policy: Mapped[str] = mapped_column(String(40), nullable=False,
        default='LEGACY_UNSPECIFIED', server_default='LEGACY_UNSPECIFIED')


class WalletBindingChallenge(Base):
    __tablename__ = 'wallet_binding_challenges'
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    session_digest: Mapped[str] = mapped_column(String(64), nullable=False)
    domain: Mapped[str] = mapped_column(String(255), nullable=False)
    network: Mapped[str] = mapped_column(String(32), nullable=False)
    address: Mapped[str] = mapped_column(String(34), nullable=False)
    expected_version: Mapped[int] = mapped_column(nullable=False)
    message: Mapped[str] = mapped_column(Text, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class WalletBindingRequest(Base):
    __tablename__ = 'wallet_binding_requests'
    __table_args__ = (UniqueConstraint('user_id', 'operation', 'idempotency_key', name='uq_wallet_binding_request'),)
    id: Mapped[str] = mapped_column(String(36), primary_key=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False)
    operation: Mapped[str] = mapped_column(String(16), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(128), nullable=False)
    digest: Mapped[str] = mapped_column(String(64), nullable=False)
    response: Mapped[dict] = mapped_column(JSON, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
