import pytest
from datetime import datetime, timezone
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from httpx import AsyncClient, ASGITransport
from app.core.database import Base, create_session_factory
from app.core.config import Settings
from app.main import create_app
from app.modules.identity.models import User, UserRole
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.tokens import TokenService

@pytest.fixture()
def admin_app():
    engine=create_engine("sqlite+pysqlite:///:memory:",connect_args={"check_same_thread":False},poolclass=StaticPool)
    Base.metadata.create_all(engine); factory=create_session_factory(engine)
    now=datetime.now(timezone.utc)
    with factory.begin() as s:
        s.add(User(id="admin-1",username="admin",username_normalized="admin",email="a@x.com",email_normalized="a@x.com",password_hash="x",status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
        s.add(UserRole(id="r1",user_id="admin-1",role_code=RoleCode.SUPER_ADMIN,assigned_by="bootstrap",assigned_at=now))
        s.add(User(id="u1",username="user",username_normalized="user",email="u@x.com",email_normalized="u@x.com",password_hash="x",status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
    settings=Settings(_env_file=None,environment="test",database_url="sqlite+pysqlite:///:memory:",jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    app=create_app(settings,session_factory=factory)
    token=TokenService(factory,jwt_secret=settings.jwt_secret,jwt_issuer=settings.jwt_issuer,require_session_claims=False).issue_pair(user_id="admin-1",device_key="d",display_name="a").access_token
    return app,token

@pytest.mark.asyncio
async def test_admin_session_returns_permissions_and_brand(admin_app):
    app,t=admin_app
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        r=await c.get("/api/v1/admin/session",headers={"Authorization":f"Bearer {t}"})
    assert r.status_code==200; body=r.json(); assert body["user_id"]=="admin-1"; assert "system.admin" in body["permissions"]; assert body["brand"]=="ChatFlow"

@pytest.mark.asyncio
async def test_admin_overview_requires_rbac(admin_app):
    app,t=admin_app
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        r=await c.get("/api/v1/admin/overview",headers={"Authorization":f"Bearer {t}"})
    assert r.status_code==200; assert "registered_users" in r.json()
