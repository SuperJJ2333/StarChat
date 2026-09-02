"""投诉：类型校验 + 落库 + 鉴权。"""
from datetime import datetime, timedelta, timezone

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


@pytest.fixture()
def context():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id="u1", username="alice", username_normalized="alice", email="a@x.com", email_normalized="a@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", redis_url="redis://localhost:6379/15", jwt_secret="r" * 32, totp_issuer="六合通")
    app = create_app(settings, session_factory=factory)
    yield app, factory, settings
    engine.dispose()


def bearer(settings, user_id):
    now = datetime.now(timezone.utc)
    value = jwt.encode({"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())}, settings.jwt_secret, algorithm="HS256")
    return {"Authorization": f"Bearer {value}"}


@pytest.mark.asyncio
async def test_complaint_requires_authentication(context):
    app, _factory, _settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/api/v1/support/complaints", json={"category": "骚扰行为", "description": "骚扰我"})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_complaint_is_recorded(context):
    app, factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/api/v1/support/complaints", headers=bearer(settings, "u1"), json={"category": "骚扰行为", "description": "对方多次骚扰我"})
    assert response.status_code == 201
    assert response.json()["category"] == "骚扰行为"
    from app.modules.friendship.models import Complaint
    with factory() as session:
        rows = session.query(Complaint).all()
        assert len(rows) == 1 and rows[0].user_id == "u1"


@pytest.mark.asyncio
async def test_complaint_category_is_validated(context):
    app, _factory, settings = context
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/api/v1/support/complaints", headers=bearer(settings, "u1"), json={"category": "无效类型", "description": "x"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "COMPLAINT_CATEGORY_INVALID"
