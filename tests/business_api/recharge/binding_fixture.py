"""Real, isolated wallet binding records for recharge tests."""

from uuid import uuid4

from coincurve import PrivateKey
from sqlalchemy import select

from app.integrations.tron.message_signature import address_from_public_key
from app.modules.wallet.binding_models import WalletAddressOwner, WalletBinding, WalletBindingState


def seed_active_binding(session, *, user_id, now):
    """Give a fixture account a versioned binding with activation evidence."""
    address = address_from_public_key(PrivateKey().public_key.format(compressed=False))
    binding_id = str(uuid4())
    session.add(WalletAddressOwner(address=address, user_id=user_id, created_at=now))
    session.flush()
    session.add(WalletBinding(
        id=binding_id, user_id=user_id, address=address, version=1, status="ACTIVE",
        created_at=now, activated_at=now, effective_from_block=101,
        barrier_height=100, barrier_block_id="a" * 64,
        barrier_source_ids=["isolated-recharge-fixture"], barrier_observed_at=now,
    ))
    session.add(WalletBindingState(user_id=user_id, version=1, active_binding_id=binding_id))


def wallet_binding_snapshot(session):
    """Capture persisted wallet rows so a read gate cannot silently mutate them."""
    return tuple(
        tuple(sorted(
            (tuple(getattr(row, column.key) for column in model.__table__.columns)
             for row in session.scalars(select(model))),
            key=lambda values: values[0],
        ))
        for model in (WalletAddressOwner, WalletBinding, WalletBindingState)
    )
