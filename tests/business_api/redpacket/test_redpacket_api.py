from datetime import datetime, timedelta, timezone
from decimal import Decimal

import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.ledger.service import LedgerService

class FakeMatrixGateway:
    """F06：成员关系测试替身——Matrix join 成员集合按房间返回。"""

    def __init__(self):
        self.rooms: dict[str, set[str]] = {}

    def get_room_members(self, room_id: str) -> set[str]:
        return set(self.rooms.get(room_id, set()))


def seed_user(now, user_id, username, *, matrix_user_id=None, nickname=None):
    return User(
        id=user_id,
        username=username,
        username_normalized=username,
        email=f"{username}@example.com",
        email_normalized=f"{username}@example.com",
        password_hash="x",
        status=AccountStatus.ACTIVE,
        matrix_user_id=matrix_user_id or f"@{user_id}:example.test",
        nickname=nickname,
        created_at=now,
        updated_at=now,
    )


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    # F06：注入成员权威（业务用户 → Matrix ID 解析 + 假网关成员集合）。
    gateway = FakeMatrixGateway()
    gateway.rooms["!room:test"] = {"@sender:example.test", "@alice:example.test"}
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(seed_user(now, "sender", "sender01", nickname="发送者甲"))
        session.add(seed_user(now, "alice", "alice88", nickname="艾丽"))
    LedgerService(factory).adjust(user_id="sender", amount=Decimal("10.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="api-seed")
    yield app, factory, settings, gateway
    engine.dispose()

def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}

@pytest.mark.asyncio
async def test_red_packet_create_claim_and_cancel_permissions(context):
    app, factory, settings, _gateway = context
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(UserRole(id="support-role", user_id="support", role_code=RoleCode.SUPPORT_AGENT, assigned_by="admin", assigned_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "create-api"}, json={"mode": "EQUAL", "total": "2.00", "share_count": 2, "room_id": "!room:test"})
        assert created.status_code == 201
        packet_id = created.json()["id"]
        detail = await client.get(f"/api/v1/red-packets/{packet_id}", headers=bearer(settings, "sender"))
        assert detail.status_code == 200
        assert detail.json()["status"] == "OPEN"
        assert detail.json()["claimed_count"] == 0
        claimed = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "alice"), "Idempotency-Key": "claim-api"})
        assert claimed.status_code == 201
        after = await client.get(f"/api/v1/red-packets/{packet_id}", headers=bearer(settings, "alice"))
        assert after.json()["claimed_count"] == 1
        assert after.json()["claims"][0]["user_id"] == "alice"
        forbidden = await client.post(f"/api/v1/red-packets/{packet_id}/cancel", headers={**bearer(settings, "alice"), "Idempotency-Key": "cancel-forbidden"}, json={"reason_code": "ABNORMAL_RED_PACKET"})
        assert forbidden.status_code == 403
        cancelled = await client.post(f"/api/v1/red-packets/{packet_id}/cancel", headers={**bearer(settings, "support"), "Idempotency-Key": "cancel-api"}, json={"reason_code": "ABNORMAL_RED_PACKET"})
        assert cancelled.status_code == 200

@pytest.mark.asyncio
async def test_red_packet_detail_includes_claimer_public_profiles(context):
    """领取详情为领取人/发送人补充用户名、昵称与自定义头像字段。"""
    app, factory, settings, _gateway = context

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "create-profiles"}, json={"mode": "EQUAL", "total": "1.00", "share_count": 1, "room_id": "!room:test"})
        assert created.status_code == 201
        packet_id = created.json()["id"]
        claimed = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "alice"), "Idempotency-Key": "claim-profiles"})
        assert claimed.status_code == 201
        detail = await client.get(f"/api/v1/red-packets/{packet_id}", headers=bearer(settings, "sender"))
        assert detail.status_code == 200
        payload = detail.json()
        claim = payload["claims"][0]
        assert claim["nickname"] == "艾丽"
        assert claim["username"] == "alice88"
        assert "avatar_url" in claim
        assert payload["sender_nickname"] == "发送者甲"
        assert payload["sender_username"] == "sender01"


@pytest.mark.asyncio
async def test_f06_non_member_claim_and_detail_forbidden_via_route(context):
    """F06 路由级验收：非成员领取/查看群红包 → 403，且无领取副作用。"""
    app, factory, settings, gateway = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "f06-create"}, json={"mode": "EQUAL", "total": "2.00", "share_count": 2, "room_id": "!room:test"})
        assert created.status_code == 201
        packet_id = created.json()["id"]

        # mallory 不是房间成员（Matrix 权威成员集合未包含其 ID）。
        detail = await client.get(f"/api/v1/red-packets/{packet_id}", headers=bearer(settings, "mallory"))
        assert detail.status_code == 403
        assert detail.json()["error"]["code"] == "RED_PACKET_ROOM_FORBIDDEN"
        claim = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "mallory"), "Idempotency-Key": "f06-claim"}, )
        assert claim.status_code == 403

        # alice 退群（成员集合变化）→ 立即不可见/不可领。
        gateway.rooms["!room:test"] = {"@sender:example.test"}
        left = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "alice"), "Idempotency-Key": "f06-claim-left"})
        assert left.status_code == 403
