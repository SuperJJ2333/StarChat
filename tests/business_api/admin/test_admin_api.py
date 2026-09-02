import pytest
from datetime import datetime, timezone, timedelta
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool
from httpx import AsyncClient, ASGITransport
from app.core.database import Base, create_session_factory
from app.core.config import Settings
from app.main import create_app
from app.modules.identity.models import User, UserRole
from app.modules.ledger.models import LedgerTransaction, LedgerEntry
from app.modules.wallet.models import Withdrawal
from app.modules.moments.models import NativeMomentAd
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.tokens import TokenService
from app.modules.admin.service import AdminControlService
from app.modules.admin.models import OfficialNotice, NoticeReceipt
from app.modules.audit.models import AuditEvent
from app.core.outbox import OutboxEvent

@pytest.fixture()
def admin_app():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine); factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add_all([
            User(id="admin-1", username="admin", username_normalized="admin", email="a@x.com", email_normalized="a@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            User(id="finance-1", username="finance", username_normalized="finance", email="f@x.com", email_normalized="f@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            User(id="u1", username="user", username_normalized="user", email="u@x.com", email_normalized="u@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            UserRole(id="r1", user_id="admin-1", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now),
            UserRole(id="r2", user_id="finance-1", role_code=RoleCode.FINANCE_SUPPORT, assigned_by="admin-1", assigned_at=now),
        ])
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    app = create_app(settings, session_factory=factory)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    return app, tokens.issue_pair(user_id="admin-1", device_key="admin-device", display_name="admin").access_token, tokens.issue_pair(user_id="finance-1", device_key="finance-device", display_name="finance").access_token

@pytest.mark.asyncio
async def test_admin_session_returns_permissions_and_brand(admin_app):
    app, token, _ = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/admin/session", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200
    assert "system.admin" in response.json()["permissions"]
    assert response.json()["brand"] == "ChatFlow"

@pytest.mark.asyncio
async def test_admin_overview_requires_rbac(admin_app):
    app, token, _ = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/admin/overview", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200
    assert "registered_users" in response.json()

@pytest.mark.asyncio
async def test_finance_context_is_scoped_and_does_not_leak_admin_modules(admin_app):
    app, _, token = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/admin/context", headers={"Authorization": f"Bearer {token}"})
        forbidden = await client.get("/api/v1/admin/modules/analytics", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 200
    body = response.json()
    assert body["overview"] == {}
    assert "admin.withdrawals.read" in body["permissions"]
    assert "wallet" in body["modules"]
    assert "analytics" not in body["modules"]
    assert forbidden.status_code == 403

@pytest.mark.asyncio
async def test_admin_modules_return_real_ledger_wallet_and_ads_data(admin_app):
    app, token, _ = admin_app
    # Seed domain records through the same database bound to the app.
    factory = app.state.session_factory
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(LedgerTransaction(id="tx-1", asset="CAIBI", scope="ledger.post", idempotency_key="k1", actor_id="admin-1", reason_code="TEST", created_at=now))
        session.add(LedgerEntry(id="entry-1", transaction_id="tx-1", account_id="u1", asset="CAIBI", amount=12.34, created_at=now))
        session.add(Withdrawal(id="wd-1", user_id="u1", client_order_id="order-1", address="TXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", amount=1.250000, status="REQUESTED", created_at=now, updated_at=now))
        session.add(NativeMomentAd(id="ad-1", advertiser_name="Demo", avatar_url=None, text="hello", image_urls=[], link_url="https://example.com", status="ACTIVE", created_at=now))
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        ledger = await client.get("/api/v1/admin/modules/ledger", headers={"Authorization": f"Bearer {token}"})
        wallet = await client.get("/api/v1/admin/modules/wallet", headers={"Authorization": f"Bearer {token}"})
        ads = await client.get("/api/v1/admin/modules/ads", headers={"Authorization": f"Bearer {token}"})
    assert ledger.status_code == wallet.status_code == ads.status_code == 200
    assert ledger.json()["items"][0]["transaction_id"] == "tx-1"
    assert ledger.json()["items"][0]["amount"] == "12.34"
    assert wallet.json()["items"][0]["id"] == "wd-1"
    assert wallet.json()["items"][0]["address"] == "T***XXXX"
    assert ads.json()["items"][0]["id"] == "ad-1"

@pytest.mark.asyncio
async def test_admin_control_writes_require_idempotency_but_not_totp(admin_app):
    app, token, _ = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        missing_key = await client.post("/api/v1/admin/security/bans", json={"target_type":"user","target":"u1","reason_code":"ABUSE","duration_minutes":60}, headers={"Authorization": f"Bearer {token}"})
        direct_write = await client.post("/api/v1/admin/support-roles/u1", json={"role_code":"SUPPORT_AGENT"}, headers={"Authorization": f"Bearer {token}", "Idempotency-Key":"role-1"})
    assert missing_key.status_code == 422
    assert direct_write.status_code == 201


@pytest.mark.asyncio
async def test_admin_notice_and_ad_commands_persist_and_emit_audit(admin_app):
    app, token, _ = admin_app
    headers={"Authorization": f"Bearer {token}", "Idempotency-Key":"ad-1"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        ad = await client.post("/api/v1/admin/ads", json={"advertiser_name":"Demo","text":"hello","link_url":"https://example.com"}, headers=headers)
    assert ad.status_code == 201
    assert ad.json()["advertiser_name"] == "Demo"
    with app.state.session_factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == "admin.ad.created")) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "native_ad.created")) is not None

@pytest.mark.asyncio
async def test_system_admin_updates_notice_directly_with_idempotency_audit_and_outbox(admin_app):
    app, token, _ = admin_app
    create_headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": "notice-direct-create"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post(
            "/api/v1/admin/notices",
            json={"title": "原公告", "content": "原正文", "audience": "ALL"},
            headers=create_headers,
        )
        notice_id = created.json()["id"]
        updated = await client.put(
            f"/api/v1/admin/notices/{notice_id}",
            json={"title": "已修改", "content": "无需审批或二次验证", "audience": "ACTIVE"},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "notice-direct-update"},
        )
        replay = await client.put(
            f"/api/v1/admin/notices/{notice_id}",
            json={"title": "已修改", "content": "无需审批或二次验证", "audience": "ACTIVE"},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "notice-direct-update"},
        )
    assert created.status_code == 201
    assert updated.status_code == replay.status_code == 200
    assert updated.json() == replay.json()
    assert updated.json()["title"] == "已修改"
    with app.state.session_factory() as session:
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == "admin.notice.updated")) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "notice.publish.requested")) is not None

@pytest.mark.asyncio
async def test_admin_adjustment_review_returns_stable_error_when_request_is_missing(admin_app):
    app, token, _ = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/api/v1/admin/finance/adjustments/missing-request/review",
            json={"approve": True},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "missing-adjustment"},
        )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "ADJUSTMENT_TRANSITION_INVALID"

@pytest.mark.asyncio
async def test_system_admin_can_grant_caibi_directly_to_a_support_agent_with_audit_and_outbox(admin_app):
    app, token, _ = admin_app
    headers = {"Authorization": f"Bearer {token}", "Idempotency-Key": "direct-caibi-grant"}
    payload = {"user_id": "u1", "amount": "88.00", "reason_code": "SUPPORT_CAIBI_GRANT"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        missing_role = await client.post("/api/v1/admin/finance/adjustments", json=payload, headers=headers)
        role = await client.post(
            "/api/v1/admin/support-roles/u1",
            json={"role_code": "SUPPORT_AGENT"},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "grant-support-role"},
        )
        granted = await client.post("/api/v1/admin/finance/adjustments", json=payload, headers=headers)
        replay = await client.post("/api/v1/admin/finance/adjustments", json=payload, headers=headers)
    assert missing_role.status_code == 422
    assert missing_role.json()["error"]["code"] == "SUPPORT_ROLE_REQUIRED"
    assert role.status_code == 201
    assert granted.status_code == replay.status_code == 201
    assert granted.json() == replay.json()
    assert granted.json()["amount"] == "88.00"
    with app.state.session_factory() as session:
        assert session.scalar(select(LedgerEntry).where(LedgerEntry.account_id == "u1", LedgerEntry.amount == 88)) is not None
        assert session.scalar(select(AuditEvent).where(AuditEvent.action == "admin.caibi.granted")) is not None
        assert session.scalar(select(OutboxEvent).where(OutboxEvent.event_type == "ledger.posted")) is not None

@pytest.mark.asyncio
async def test_admin_notice_command_persists(admin_app):
    app, token, _ = admin_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        notice = await client.post("/api/v1/admin/notices", json={"title":"维护","content":"今晚维护","audience":"ALL"}, headers={"Authorization": f"Bearer {token}", "Idempotency-Key":"notice-1"})
    assert notice.status_code == 201
    assert notice.json()["title"] == "维护"

def test_notice_can_be_edited_retracted_and_read_with_idempotent_receipt(admin_app):
    app, _, _ = admin_app
    service = AdminControlService(app.state.session_factory)
    created = service.create_notice(actor_id="admin-1", title="原公告", content="正文", audience="ALL", publish_at=None, idempotency_key="notice-create", trace_id="t1")
    updated = service.update_notice(actor_id="admin-1", notice_id=created["id"], title="新公告", content="新正文", audience="ACTIVE", publish_at=None, idempotency_key="notice-edit", trace_id="t2")
    assert updated["title"] == "新公告"
    first = service.record_notice_read(user_id="u1", notice_id=created["id"], idempotency_key="notice-read")
    second = service.record_notice_read(user_id="u1", notice_id=created["id"], idempotency_key="notice-read")
    assert first == second
    retracted = service.retract_notice(actor_id="admin-1", notice_id=created["id"], reason_code="NOTICE_RETRACT", idempotency_key="notice-retract", trace_id="t3")
    assert retracted["status"] == "RETRACTED"
    with app.state.session_factory() as session:
        assert session.get(OfficialNotice, created["id"]).status == "RETRACTED"
        assert session.scalar(select(NoticeReceipt).where(NoticeReceipt.notice_id == created["id"])) is not None
