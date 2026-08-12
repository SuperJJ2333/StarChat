from datetime import datetime, timedelta, timezone

import jwt
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import UserRole

@pytest.fixture()
def app_context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="x" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    yield app, factory, settings
    engine.dispose()

def token(settings, user_id):
    now = datetime.now(timezone.utc)
    return jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")

@pytest.mark.asyncio
async def test_support_api_requires_role_and_exposes_official_identity(app_context):
    app, factory, settings = app_context
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(UserRole(id="r1", user_id="agent-1", role_code=RoleCode.SUPPORT_AGENT, assigned_by="admin", assigned_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        identity = await client.get("/api/v1/support/identities/agent-1")
        assert identity.status_code == 200
        assert identity.json()["badge"] == "官方客服"
        opened = await client.post("/api/v1/support/tickets", headers={"Authorization": f"Bearer {token(settings, 'user-1')}"}, json={"room_id": "!opaque:test", "skill": "billing"})
        assert opened.status_code == 201
        forbidden = await client.post(f"/api/v1/support/tickets/{opened.json()['id']}/close", headers={"Authorization": f"Bearer {token(settings, 'user-1')}"})
        assert forbidden.status_code == 403

