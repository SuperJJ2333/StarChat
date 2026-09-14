import hashlib
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.pool import StaticPool
from sqlalchemy import create_engine

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxEvent
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.admin.models import AdminCommand
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.tokens import TokenService


@pytest.fixture()
def support_admin_app():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add_all([
            User(id="admin", username="admin", username_normalized="admin", email="admin@example.com", email_normalized="admin@example.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            User(id="agent", username="chat-agent", username_normalized="chat-agent", nickname="客服小王", email="Agent@Example.COM", email_normalized="agent@example.com", password_hash="x", status=AccountStatus.ACTIVE, matrix_user_id="@agent:chatflow.test", created_at=now, updated_at=now),
            User(id="other", username="other", username_normalized="other", nickname="客服小李", email="other@example.com", email_normalized="other@example.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            UserRole(id="admin-role", user_id="admin", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now),
            UserRole(id="agent-admin", user_id="agent", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now),
            UserRole(id="agent-user", user_id="agent", role_code=RoleCode.USER, assigned_by="bootstrap", assigned_at=now + timedelta(seconds=1)),
        ])
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", jwt_secret="x" * 32)
    app = create_app(settings, session_factory=factory)
    token = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False).issue_admin_pair(user_id="admin", display_name="admin").access_token
    yield app, token
    engine.dispose()


@pytest.mark.asyncio
async def test_support_role_resolves_exact_email_updates_badge_and_lists_masked_results(support_admin_app):
    app, token = support_admin_app
    headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": "support-grant-1"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        granted = await client.post("/api/v1/admin/support-roles/Agent%40Example.COM", json={"role_code": "SUPPORT_AGENT", "badge": "专属客服"}, headers=headers)
        replay = await client.post("/api/v1/admin/support-roles/Agent%40Example.COM", json={"role_code": "SUPPORT_AGENT", "badge": "专属客服"}, headers=headers)
        second = await client.post("/api/v1/admin/support-roles/other", json={}, headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "second-agent"})
        listed = await client.get("/api/v1/admin/support-agents?query=%E5%AE%A2%E6%9C%8D&limit=10&offset=0", headers={"Authorization": f"Bearer {token}"})
        page = await client.get("/api/v1/admin/support-agents?limit=1&offset=1", headers={"Authorization": f"Bearer {token}"})
        literal = await client.get("/api/v1/admin/support-agents?query=%25&limit=10", headers={"Authorization": f"Bearer {token}"})
    assert granted.status_code == replay.status_code == 201
    assert second.status_code == 201
    assert granted.json() == replay.json()
    assert granted.json()["user_id"] == "agent"
    assert listed.status_code == 200
    item = next(row for row in listed.json()["items"] if row["id"] == "agent")
    assert item["badge"] == "专属客服"
    assert item["masked_email"] == "a***@example.com"
    assert "email" not in item
    assert page.status_code == 200 and page.json()["total"] == 2 and len(page.json()["items"]) == 1
    assert literal.status_code == 200 and literal.json()["total"] == 0
    with app.state.session_factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == "admin.support_role.assigned")) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "admin.support_role.assigned")) is not None


@pytest.mark.asyncio
async def test_support_badge_validation_and_remove_all_support_roles_preserves_super_admin(support_admin_app):
    app, token = support_admin_app
    auth = {"Authorization": f"Bearer {token}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        invalid = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "客服A"}, headers={**auth, "Idempotency-Key": "invalid"})
        too_short = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "官"}, headers={**auth, "Idempotency-Key": "too-short"})
        too_long = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "客服专员官方一"}, headers={**auth, "Idempotency-Key": "too-long"})
        default = await client.post("/api/v1/admin/support-roles/agent", json={}, headers={**auth, "Idempotency-Key": "default"})
        two = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "客服"}, headers={**auth, "Idempotency-Key": "two"})
        six = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "客服专员官方"}, headers={**auth, "Idempotency-Key": "six"})
        preserve = await client.post("/api/v1/admin/support-roles/agent", json={}, headers={**auth, "Idempotency-Key": "preserve"})
        remove = await client.delete("/api/v1/admin/support-roles/agent", headers={**auth, "Idempotency-Key": "remove"})
        identity = await client.get("/api/v1/support/identities/agent")
    assert invalid.status_code == 422
    assert too_short.status_code == too_long.status_code == 422
    assert default.status_code == 201
    assert default.json()["badge"] == "官方客服"
    assert two.status_code == 201 and two.json()["badge"] == "客服"
    assert six.status_code == 201
    assert six.json()["badge"] == "客服专员官方"
    assert preserve.status_code == 201 and preserve.json()["badge"] == "客服专员官方"
    assert remove.status_code == 200
    assert identity.json()["badge"] == ""
    with app.state.session_factory() as session:
        assert session.scalar(select(UserRole).where(UserRole.user_id == "agent", UserRole.role_code == RoleCode.USER)) is not None
        assert session.scalar(select(UserRole).where(UserRole.user_id == "agent", UserRole.role_code == RoleCode.SUPER_ADMIN)) is not None


@pytest.mark.asyncio
async def test_support_target_refuses_id_and_changliao_number_ambiguity(support_admin_app):
    app, token = support_admin_app
    with app.state.session_factory.begin() as session:
        user = session.get(User, "other")
        user.username, user.username_normalized = "agent", "agent"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/api/v1/admin/support-roles/agent", json={}, headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "ambiguous"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "SUPPORT_TARGET_AMBIGUOUS"


@pytest.mark.asyncio
async def test_only_support_agent_is_dispatch_eligible(support_admin_app):
    app, token = support_admin_app
    headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": "supervisor"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        granted = await client.post("/api/v1/admin/support-roles/agent", json={"role_code": "SUPPORT_SUPERVISOR"}, headers=headers)
        eligible = await client.get("/api/v1/admin/support-agents?dispatch_eligible=true", headers={"Authorization": f"Bearer {token}"})
    assert granted.status_code == 201
    assert eligible.status_code == 200
    assert all(item["id"] != "agent" for item in eligible.json()["items"])


@pytest.mark.asyncio
async def test_finance_grant_accepts_email_and_changliao_alias_but_requires_support_agent(support_admin_app):
    app, token = support_admin_app
    auth = {"Authorization": f"Bearer {token}"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        role = await client.post("/api/v1/admin/support-roles/chat-agent", json={}, headers={**auth, "Idempotency-Key": "agent-role"})
        granted = await client.post("/api/v1/admin/finance/adjustments", json={"user_id": "Agent@Example.COM", "amount": "12.34"}, headers={**auth, "Idempotency-Key": "email-grant"})
        replay = await client.post("/api/v1/admin/finance/adjustments", json={"user_id": "chat-agent", "amount": "12.34"}, headers={**auth, "Idempotency-Key": "email-grant"})
        denied = await client.post("/api/v1/admin/finance/adjustments", json={"user_id": "other", "amount": "1.00"}, headers={**auth, "Idempotency-Key": "not-agent"})
    assert role.status_code == 201
    assert granted.status_code == replay.status_code == 201
    assert granted.json()["user_id"] == replay.json()["user_id"] == "agent"
    assert granted.json()["amount"] == "12.34"
    assert granted.json() == replay.json()
    assert denied.status_code == 422
    with app.state.session_factory() as session:
        from app.modules.ledger.models import LedgerEntry
        assert len(session.scalars(select(LedgerEntry).where(LedgerEntry.account_id == "agent")).all()) == 1


@pytest.mark.asyncio
async def test_old_support_role_command_replays_and_new_badge_conflicts(support_admin_app):
    app, token = support_admin_app
    payload = {"user_id": "agent", "role_code": "SUPPORT_AGENT"}
    with app.state.session_factory.begin() as session:
        session.add(AdminCommand(id=str(uuid4()), scope="admin.support-role", idempotency_key="old-command", request_hash=hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest(), result={"user_id": "agent", "role_code": "SUPPORT_AGENT", "status": "ASSIGNED"}, created_at=datetime.now(timezone.utc)))
    auth = {"Authorization": f"Bearer {token}", "Idempotency-Key": "old-command"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        replay = await client.post("/api/v1/admin/support-roles/agent", json={}, headers=auth)
        conflict = await client.post("/api/v1/admin/support-roles/agent", json={"badge": "客服"}, headers=auth)
    assert replay.status_code == 201
    assert replay.json()["status"] == "ASSIGNED"
    assert conflict.status_code == 409


@pytest.mark.asyncio
async def test_all_revoke_preserves_only_user_and_super_admin_and_stops_assignment(support_admin_app):
    app, token = support_admin_app
    auth = {"Authorization": f"Bearer {token}"}
    from app.modules.support.service import SupportQueueService
    queue = SupportQueueService(app.state.session_factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        for role in ("SUPPORT_AGENT", "FINANCE_SUPPORT", "SUPPORT_SUPERVISOR"):
            response = await client.post("/api/v1/admin/support-roles/agent", json={"role_code": role}, headers={**auth, "Idempotency-Key": f"three-{role}"})
            assert response.status_code == 201
        queue.set_agent_presence("agent", online=True, active_tickets=0, skills={"billing"})
        ticket = queue.open_ticket("customer", "!room:test", "billing")
        removed = await client.delete("/api/v1/admin/support-roles/Agent%40Example.COM", headers={**auth, "Idempotency-Key": "remove-all"})
    assert removed.status_code == 200
    with app.state.session_factory() as session:
        roles = {role.value for role in session.scalars(select(UserRole.role_code).where(UserRole.user_id == "agent"))}
    assert roles == {"USER", "SUPER_ADMIN"}
    with pytest.raises(ValueError, match="no eligible support agent"):
        queue.assign_next(ticket.id)


@pytest.mark.asyncio
async def test_identity_lookup_requires_auth_maps_real_ids_and_never_leaks_email(support_admin_app):
    app, token = support_admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        rejected = await client.post("/api/v1/support/identities/lookup", json={"user_ids": ["agent"]})
        known = await client.post("/api/v1/support/identities/lookup", json={"user_ids": ["agent", "@agent:chatflow.test", "@unknown:chatflow.test", "other"]}, headers={"Authorization": f"Bearer {token}"})
        boundary = await client.post("/api/v1/support/identities/lookup", json={"user_ids": ["agent"] * 100}, headers={"Authorization": f"Bearer {token}"})
        overflow = await client.post("/api/v1/support/identities/lookup", json={"user_ids": ["agent"] * 101}, headers={"Authorization": f"Bearer {token}"})
    assert rejected.status_code == 401
    assert known.status_code == 200
    assert known.headers["cache-control"] == "no-store"
    items = known.json()["items"]
    assert {item["user_id"] for item in items} == {"agent", "other"}
    agent = next(item for item in items if item["user_id"] == "agent")
    other = next(item for item in items if item["user_id"] == "other")
    assert agent["query_id"] == "agent" and agent["matrix_user_id"] == "@agent:chatflow.test"
    assert other["badge"] == "" and other["role"] == "USER"
    assert "email" not in json.dumps(items)
    assert boundary.status_code == 200
    assert overflow.status_code == 422
