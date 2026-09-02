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

@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    LedgerService(factory).adjust(user_id="sender", amount=Decimal("10.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="api-seed")
    yield app, factory, settings
    engine.dispose()

def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}

@pytest.mark.asyncio
async def test_red_packet_create_claim_and_cancel_permissions(context):
    app, factory, settings = context
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
    app, factory, settings = context
    now = datetime.now(timezone.utc)

    def seed_user(user_id, username, nickname):
        return User(
            id=user_id,
            username=username,
            username_normalized=username,
            email=f"{username}@example.com",
            email_normalized=f"{username}@example.com",
            password_hash="x",
            status=AccountStatus.ACTIVE,
            nickname=nickname,
            created_at=now,
            updated_at=now,
        )

    with factory.begin() as session:
        session.add(seed_user("sender", "sender01", "发送者甲"))
        session.add(seed_user("alice", "alice88", "艾丽"))
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
