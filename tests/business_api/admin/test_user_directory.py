"""Administrator-only directory: authoritative contacts, roles and CAIBI."""
import base64
import hashlib
import json
from datetime import datetime, timezone
from decimal import Decimal

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import event, select

from app.core.config import Settings
from app.modules.admin.user_directory import UserDirectoryService
from app.modules.audit.models import AuditEvent
from app.modules.audit.writer import AuditWriter
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.tokens import TokenService
from app.modules.ledger.models import LedgerEntry, LedgerTransaction
from app.modules.support.service import SupportProfile, SupportQueueService
from test_admin_api import admin_app  # noqa: F401


PATH = "/api/v1/admin/users/search"
ORIGIN = {"Origin": "http://test", "X-Admin-CSRF": "1"}
STAMP = datetime(2026, 9, 10, 1, 2, 3, tzinfo=timezone.utc)


def directory_headers(token):
    return {"Authorization": f"Bearer {token}", **ORIGIN}


def seed_users(factory, count=150):
    with factory.begin() as session:
        for index in range(count):
            session.add(User(
                id=f"member-{index:03}", username=f"member{index:03}",
                username_normalized=f"member{index:03}", nickname=f"成员{index:03}",
                email=f"member{index:03}@example.test",
                email_normalized=f"member{index:03}@example.test",
                phone=f"+86138000{index:05}", phone_normalized=f"+86138000{index:05}",
                phone_verified_at=STAMP if index == 149 else None,
                email_verified_at=STAMP if index == 149 else None,
                password_hash="private-hash", matrix_user_id=f"@member{index}:example.test",
                status=AccountStatus.DISABLED if index == 149 else AccountStatus.ACTIVE,
                created_at=STAMP, updated_at=STAMP,
            ))


def seed_directory_evidence(factory):
    seed_users(factory)
    with factory.begin() as session:
        session.add(UserRole(id="support-dir", user_id="member-149",
            role_code=RoleCode.FINANCE_SUPPORT, assigned_by="admin-1", assigned_at=STAMP))
        session.add(SupportProfile(user_id="member-149", badge="财经客服", updated_at=STAMP))
        session.add_all([
            LedgerTransaction(id="directory-caibi", asset="CAIBI", scope="test",
                idempotency_key="directory-caibi", actor_id="admin-1", reason_code="TEST", created_at=STAMP),
            LedgerTransaction(id="directory-usdt", asset="USDT", scope="test",
                idempotency_key="directory-usdt", actor_id="admin-1", reason_code="TEST", created_at=STAMP),
        ])
        session.flush()
        session.add_all([
            LedgerEntry(id="directory-entry", transaction_id="directory-caibi", asset="CAIBI",
                account_id="member-149", amount=Decimal("1234567890123.45"), created_at=STAMP),
            LedgerEntry(id="directory-usdt-entry", transaction_id="directory-usdt", asset="USDT",
                account_id="member-148", amount=Decimal("9.99"), created_at=STAMP),
        ])


def test_official_titles_require_current_role_even_with_stale_profile(admin_app):
    app, _, _ = admin_app
    factory = app.state.session_factory
    seed_directory_evidence(factory)
    directory = SupportQueueService(factory)
    assert directory.official_titles_for(["member-149", "member-148"]) == {
        "member-149": "财经客服"}
    with factory.begin() as session:
        session.delete(session.get(UserRole, "support-dir"))
    assert directory.official_titles_for(["member-149"]) == {}


@pytest.mark.asyncio
async def test_directory_stable_150_users_pages_and_batch_evidence(admin_app):
    app, admin_token, _ = admin_app
    seed_directory_evidence(app.state.session_factory)
    engine = app.state.session_factory.kw["bind"]
    selects = []

    def record(_conn, _cursor, statement, _parameters, _context, _executemany):
        if statement.lstrip().upper().startswith("SELECT"):
            selects.append(statement)

    event.listen(engine, "before_cursor_execute", record)
    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            cursor = None
            seen = []
            for page_number in range(3):
                body = {"q": "member", "limit": 50}
                if cursor:
                    body["cursor"] = cursor
                before = len(selects)
                response = await client.post(PATH, json=body, headers=directory_headers(admin_token))
                assert response.status_code == 200, response.text
                assert response.headers["Cache-Control"] == "no-store"
                page = response.json()
                assert page["total"] == 150
                assert len(page["items"]) == 50
                balance_selects = [sql for sql in selects[before:] if "FROM ledger_entries" in sql]
                assert len(balance_selects) == 1
                assert "GROUP BY ledger_entries.account_id" in balance_selects[0]
                seen.extend(page["items"])
                cursor = page["next_cursor"]
                assert (cursor is None) == (page_number == 2)
    finally:
        event.remove(engine, "before_cursor_execute", record)
    assert [item["id"] for item in seen] == [f"member-{i:03}" for i in range(149, -1, -1)]
    top = seen[0]
    assert top == {
        "id": "member-149", "username": "member149", "nickname": "成员149",
        "status": "DISABLED", "email": "member149@example.test",
        "email_verified_at": "2026-09-10T01:02:03+00:00",
        "phone": "+8613800000149", "phone_verified_at": "2026-09-10T01:02:03+00:00",
        "caibi_balance": "1234567890123.45", "official_support_title": "财经客服",
    }
    assert seen[1]["caibi_balance"] == "0.00"  # USDT does not count.
    assert seen[1]["official_support_title"] is None
    assert not {"password_hash", "matrix_user_id", "wallet_address"} & top.keys()


@pytest.mark.asyncio
@pytest.mark.parametrize("query,expected", [
    ("MEMBER149", "member-149"), ("成员149", "member-149"),
    ("MEMBER149@EXAMPLE.TEST", "member-149"), ("+8613800000149", "member-149"),
])
async def test_directory_searches_all_requested_columns(admin_app, query, expected):
    app, token, _ = admin_app
    seed_users(app.state.session_factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(PATH, json={"q": query}, headers=directory_headers(token))
    assert response.status_code == 200, response.text
    assert [item["id"] for item in response.json()["items"]] == [expected]


@pytest.mark.asyncio
async def test_directory_cursor_filter_invalid_inputs_and_revoked_title(admin_app):
    app, token, _ = admin_app
    seed_directory_evidence(app.state.session_factory)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await client.post(PATH, json={"q": "member", "limit": 1}, headers=directory_headers(token))
        assert first.status_code == 200, first.text
        cursor = first.json()["next_cursor"]
        for body in ({"q": "other", "cursor": cursor}, {"cursor": "bad"},
                {"limit": 0}, {"limit": 101}, {"q": "x" * 129}):
            invalid = await client.post(PATH, json=body, headers=directory_headers(token))
            assert invalid.status_code == 422
        with app.state.session_factory.begin() as session:
            session.delete(session.get(UserRole, "support-dir"))
        after_revoke = await client.post(PATH, json={"q": "member149"}, headers=directory_headers(token))
    assert after_revoke.status_code == 200
    assert after_revoke.json()["items"][0]["official_support_title"] is None


@pytest.mark.asyncio
async def test_directory_cursor_rejects_changed_page_boundary_with_original_signature(admin_app):
    app, token, _ = admin_app
    seed_users(app.state.session_factory, 3)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await client.post(PATH, json={"q": "member", "limit": 1},
            headers=directory_headers(token))
        assert first.status_code == 200, first.text
        cursor = first.json()["next_cursor"]
        assert cursor is not None
        original = json.loads(base64.urlsafe_b64decode(cursor))
        valid = await client.post(PATH, json={"q": "member", "limit": 1, "cursor": cursor},
            headers=directory_headers(token))
        assert valid.status_code == 200, valid.text
        for position, replacement in ((0, "2026-09-11T01:02:03+00:00"),
                                      (1, "member-000")):
            altered = list(original)
            altered[position] = replacement
            forged = base64.urlsafe_b64encode(json.dumps(altered,
                separators=(",", ":")).encode()).decode()
            response = await client.post(PATH,
                json={"q": "member", "limit": 1, "cursor": forged},
                headers=directory_headers(token))
            assert response.status_code == 422, response.text


@pytest.mark.asyncio
async def test_directory_requires_management_session_origin_csrf_and_system_admin(admin_app):
    app, admin_token, finance_token = admin_app
    settings = Settings(_env_file=None, environment="test",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    tokens = TokenService(app.state.session_factory, jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer)
    app_token = tokens.issue_pair(user_id="admin-1", device_key="directory-app", display_name="app").access_token
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        cases = [
            ({}, 401),
            (directory_headers(finance_token), 403),
            (directory_headers(app_token), 401),
            ({"Authorization": f"Bearer {admin_token}"}, 403),
            ({"Authorization": f"Bearer {admin_token}", "Origin": "https://evil.example", "X-Admin-CSRF": "1"}, 403),
            ({"Authorization": f"Bearer {admin_token}", "Origin": "http://test"}, 403),
        ]
        for headers, expected in cases:
            response = await client.post(PATH, json={}, headers=headers)
            assert response.status_code == expected, response.text


@pytest.mark.asyncio
async def test_directory_audit_keeps_raw_contact_out_and_old_reads_redacted(admin_app):
    app, token, _ = admin_app
    seed_users(app.state.session_factory, 1)
    contact = "member000@example.test"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        searched = await client.post(PATH, json={"q": contact}, headers=directory_headers(token))
        context = await client.get("/api/v1/admin/context", headers={"Authorization": f"Bearer {token}"})
        analytics = await client.get("/api/v1/admin/modules/analytics", headers={"Authorization": f"Bearer {token}"})
        security = await client.get("/api/v1/admin/modules/security", headers={"Authorization": f"Bearer {token}"})
    assert searched.status_code == context.status_code == analytics.status_code == security.status_code == 200
    assert searched.json()["items"][0]["email"] == contact
    assert contact not in context.text + analytics.text + security.text
    with app.state.session_factory() as session:
        audit = session.scalar(select(AuditEvent).where(AuditEvent.action == "admin.users.searched"))
    assert audit is not None
    assert audit.actor_id == "admin-1"
    assert contact not in str(audit.after_data)
    assert "query_digest" not in audit.after_data
    assert audit.after_data["query_present"] is True


@pytest.mark.asyncio
async def test_directory_cursor_does_not_expose_guessable_contact_digest(admin_app):
    app, token, _ = admin_app
    seed_users(app.state.session_factory, 2)
    contact = "member@example.test"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(PATH, json={"q": "member", "limit": 1},
                                     headers=directory_headers(token))
    assert response.status_code == 200
    cursor = response.json()["next_cursor"]
    decoded = json.loads(base64.urlsafe_b64decode(cursor))
    assert decoded[2] != hashlib.sha256("member".encode()).hexdigest()
    assert contact not in cursor


@pytest.mark.asyncio
async def test_directory_suppresses_contacts_if_admin_role_revoked_during_search(admin_app, monkeypatch):
    app, token, _ = admin_app
    factory = app.state.session_factory
    seed_users(factory, 1)
    original_search = UserDirectoryService.search

    def search_then_revoke(self, **kwargs):
        result = original_search(self, **kwargs)
        with factory.begin() as session:
            session.delete(session.get(UserRole, "r1"))
        return result

    monkeypatch.setattr(UserDirectoryService, "search", search_then_revoke)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(PATH, json={"q": "member000"},
                                     headers={**directory_headers(token), "X-Trace-Id": "directory-revoke"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "ADMIN_SESSION_REPLACED"
    assert "member000@example.test" not in response.text
    assert response.headers["X-Trace-Id"] == "directory-revoke"
    assert response.json()["error"]["trace_id"] == "directory-revoke"
    assert any(row["status_code"] == 401 and row["method"] == "POST"
               for row in app.state.request_latency_metrics.snapshot()["requests"])


@pytest.mark.asyncio
async def test_directory_suppresses_contacts_if_session_replaced_after_audit(admin_app, monkeypatch):
    app, token, _ = admin_app
    factory = app.state.session_factory
    seed_users(factory, 1)
    settings = Settings(_env_file=None, environment="test",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer)
    original_record = AuditWriter.record

    def record_then_replace(self, **kwargs):
        result = original_record(self, **kwargs)
        if kwargs.get("action") == "admin.users.searched":
            tokens.issue_admin_pair(user_id="admin-1", display_name="other browser")
        return result

    monkeypatch.setattr(AuditWriter, "record", record_then_replace)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(PATH, json={"q": "member000"},
                                     headers=directory_headers(token))
    assert response.status_code == 401
    assert "member000@example.test" not in response.text
