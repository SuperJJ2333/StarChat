"""Review regressions for authority and production commission wiring."""
from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.modules.groups.registry import GroupOwnerError, GroupRegistryService
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User


class Gateway:
    def __init__(self):
        self.power = {"@owner:x": 100, "@target:x": 0}
        self.members = {"@owner:x", "@target:x"}

    def get_room_state(self, room_id):
        return [
            {"type": "m.room.power_levels", "content": {"users": self.power}},
            *[{"type": "m.room.member", "state_key": member,
               "content": {"membership": "join"}} for member in self.members],
        ]

    def get_room_members(self, room_id):
        return self.members


@pytest.fixture
def review_env():
    engine = create_engine("sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id in ("owner", "target"):
            session.add(User(id=user_id, username=user_id, username_normalized=user_id,
                email=f"{user_id}@x.test", email_normalized=f"{user_id}@x.test",
                password_hash="x", status=AccountStatus.ACTIVE,
                matrix_user_id=f"@{user_id}:x", created_at=now, updated_at=now))
    gateway = Gateway()
    registry = GroupRegistryService(factory, matrix_gateway=gateway)
    yield factory, gateway, registry
    engine.dispose()


def test_registry_rejects_transfer_to_nonmember(review_env):
    _, gateway, registry = review_env
    registry.register_creation("!room:x", "owner")
    gateway.members.remove("@target:x")
    with pytest.raises(GroupOwnerError):
        registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="target")


def test_registry_rechecks_matrix_operator_permission(review_env):
    _, gateway, registry = review_env
    registry.register_creation("!room:x", "owner")
    gateway.power = {"@owner:x": 0, "@target:x": 100}
    with pytest.raises(GroupOwnerError):
        registry.transfer("!room:x", current_owner_user_id="owner", new_owner_user_id="target")


def test_departed_power_holder_cannot_register_financial_ownership(review_env):
    _, gateway, registry = review_env
    gateway.members.remove("@owner:x")
    with pytest.raises(GroupOwnerError):
        registry.register_creation("!room:x", "owner")


def test_real_redpacket_router_injects_group_authority(review_env, monkeypatch):
    from app.api import redpacket
    from app.core.config import Settings

    factory, gateway, _ = review_env
    original = redpacket.RedPacketService
    constructed = []

    def capture(*args, **kwargs):
        service = original(*args, **kwargs)
        constructed.append(service)
        return service

    monkeypatch.setattr(redpacket, "RedPacketService", capture)
    redpacket.create_redpacket_router(
        Settings(_env_file=None, environment="test", jwt_secret="x" * 32),
        factory, matrix_gateway=gateway,
    )
    assert constructed[0].group_registry is not None, "Production API bypasses owner commission/exemption"
