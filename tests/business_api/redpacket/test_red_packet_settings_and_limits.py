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
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id="admin-1", username="admin", username_normalized="admin", email="a@x.com", email_normalized="a@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
        session.add(UserRole(id="r1", user_id="admin-1", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    LedgerService(factory).adjust(user_id="sender", amount=Decimal("50000.00"), actor_id="finance", reason_code="INITIAL_CREDIT", idempotency_key="seed")
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


@pytest.mark.asyncio
async def test_red_packet_limits_endpoint_reports_runtime_cap(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/red-packets/limits", headers=bearer(settings, "sender"))
    assert response.status_code == 200
    assert response.json()["max_total"] == "20000.00"
    assert response.json()["max_share_count"] == 500
    assert response.json()["min_per_share"] == "0.01"


@pytest.mark.asyncio
async def test_admin_can_adjust_red_packet_cap_at_runtime(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        denied = await client.put("/api/v1/admin/red-packet-settings", headers={**bearer(settings, "sender"), "Idempotency-Key": "cap-1"}, json={"max_total": "500.00"})
        assert denied.status_code == 403
        updated = await client.put("/api/v1/admin/red-packet-settings", headers={**bearer(settings, "admin-1"), "Idempotency-Key": "cap-1"}, json={"max_total": "500.00"})
        assert updated.status_code == 200
        assert updated.json()["max_total"] == "500.00"
        limits = await client.get("/api/v1/red-packets/limits", headers=bearer(settings, "sender"))
        assert limits.json()["max_total"] == "500.00"
        rejected = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "cap-create"}, json={"mode": "EQUAL", "total": "600.00", "share_count": 2, "room_id": "!room:test"})
        assert rejected.status_code == 422
        assert rejected.json()["error"]["code"] == "RED_PACKET_LIMIT_EXCEEDED"
        assert "500.00" in rejected.json()["error"]["message"]
        allowed = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "cap-create-ok"}, json={"mode": "EQUAL", "total": "400.00", "share_count": 2, "room_id": "!room:test"})
        assert allowed.status_code == 201


@pytest.mark.asyncio
async def test_exclusive_red_packet_create_and_claim_flow(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "ex-1"}, json={"mode": "EXCLUSIVE", "total": "8.88", "share_count": 1, "room_id": "!room:test", "recipient_id": "alice"})
        assert created.status_code == 201
        packet_id = created.json()["id"]
        stranger = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "mallory"), "Idempotency-Key": "ex-claim-bad"})
        assert stranger.status_code == 403
        assert stranger.json()["error"]["code"] == "RED_PACKET_RECIPIENT_MISMATCH"
        claimed = await client.post(f"/api/v1/red-packets/{packet_id}/claims", headers={**bearer(settings, "alice"), "Idempotency-Key": "ex-claim"})
        assert claimed.status_code == 201
        assert claimed.json()["amount"] == "8.88"


@pytest.mark.asyncio
async def test_exclusive_red_packet_requires_recipient(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        missing_recipient = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "ex-2"}, json={"mode": "EXCLUSIVE", "total": "1.00", "share_count": 1, "room_id": "!room:test"})
        assert missing_recipient.status_code == 422
        wrong_share_count = await client.post("/api/v1/red-packets", headers={**bearer(settings, "sender"), "Idempotency-Key": "ex-3"}, json={"mode": "EXCLUSIVE", "total": "1.00", "share_count": 3, "room_id": "!room:test", "recipient_id": "alice"})
        assert wrong_share_count.status_code == 422
