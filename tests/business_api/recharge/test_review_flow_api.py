"""批次1.1 契约测试：NEEDS_REVIEW 处置 / 案件分页 / 审计时间线 / 转让复核。

- 权限：无财务权限访问管理端点 → 403；
- retry=只读核实（幂等，不二次入账）；release=服务端核证确证未执行
  （调整被拒/缺失/已冲正）才释放；超时/不确定拒绝释放；
- 转让 confirm_applied=既成事实完成；fail_unapplied=确证未应用才失败化。
"""
import asyncio
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import httpx
import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine, event, select
from sqlalchemy.orm import sessionmaker

import app.modules.audit.models  # noqa: F401
import app.modules.identity.models  # noqa: F401
import app.modules.recharge.models  # noqa: F401
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.passwords import PasswordHasher
from app.modules.identity.tokens import TokenService
from app.modules.ledger.adjustment_models import AdjustmentRequest
from app.modules.ledger.service import LedgerService
from app.modules.recharge.models import RechargeCreditBinding, RechargeRequest


@pytest.fixture()
def env(tmp_path):
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'review.db'}",
        connect_args={"check_same_thread": False, "timeout": 15})

    @event.listens_for(engine, "connect")
    def _fk(dbapi_connection, _record):
        dbapi_connection.execute("PRAGMA foreign_keys=ON")

    Base.metadata.create_all(engine)
    factory = sessionmaker(bind=engine, expire_on_commit=False)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for uid, role in (("alice", None), ("agent", RoleCode.FINANCE_SUPPORT),
                ("root", RoleCode.SUPER_ADMIN)):
            session.add(User(id=uid, username=uid, username_normalized=uid,
                email=f"{uid}@x.test", email_normalized=f"{uid}@x.test", password_hash="x",
                status="ACTIVE", created_at=now, updated_at=now))
            if role is not None:
                session.add(UserRole(id=f"r-{uid}", user_id=uid, role_code=role,
                    assigned_by="root", assigned_at=now))
        session.add(RechargeRequest(id="req-nr", user_id="alice", amount_usdt=Decimal("50"),
            evidence_txid="A" * 64, status="SUBMITTED", created_at=now, updated_at=now))
        session.add(AdjustmentRequest(id="adj-nr", user_id="alice", amount=Decimal("50.00"),
            reason_code="RECHARGE_CREDIT", status="PENDING_FINANCE", submitted_by="agent",
            idempotency_key="adj-nr-key", business_date=now.date(), created_at=now, updated_at=now))
        session.flush()  # 先落依赖行（users/requests/adjustments）
        session.add(RechargeCreditBinding(id="bind-nr", request_id="req-nr",
            adjustment_id="adj-nr", state="NEEDS_REVIEW", state_active="1",
            bound_by="agent", failure_reason="RECHARGE_PROOF_INVALID",
            created_at=now, updated_at=now))
        for index in range(3):
            session.add(RechargeRequest(id=f"req-h{index}", user_id="alice",
                amount_usdt=Decimal("10"), status="REJECTED", created_at=now,
                updated_at=now, decided_by="agent", decision_reason="r"))
    ledger = LedgerService(factory)
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    app = create_app(settings, session_factory=factory)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret,
        jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    headers = {uid: {"Authorization": f"Bearer {tokens.issue_pair(user_id=uid, device_key='d', display_name='t').access_token}"}
        for uid in ("alice", "agent", "root")}
    yield app, factory, ledger, headers
    engine.dispose()


def post(app, headers, path, json_body=None):
    async def call():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            return await client.post(path, json=json_body, headers={**headers, "Idempotency-Key": "k-" + path[-12:]})
    return asyncio.run(call())


def get(app, headers, path):
    async def call():
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            return await client.get(path, headers=headers)
    return asyncio.run(call())


def test_review_queue_requires_finance_permission(env):
    app, factory, ledger, headers = env
    response = get(app, headers["alice"], "/api/v1/recharge/admin/review-queue")
    assert response.status_code == 403
    ok = get(app, headers["agent"], "/api/v1/recharge/admin/review-queue")
    assert ok.status_code == 200
    assert ok.json()["items"][0]["state"] == "NEEDS_REVIEW"


def test_retry_without_evidence_stays_needs_review_and_never_credits(env):
    app, factory, ledger, headers = env
    response = post(app, headers["agent"], "/api/v1/recharge/admin/requests/req-nr/review",
        {"action": "retry", "binding_id": "bind-nr"})
    assert response.status_code == 200
    body = response.json()
    assert body["binding_state"] == "NEEDS_REVIEW"  # 调整仍在审批 → 不确定，不释放
    with factory() as session:
        assert session.get(RechargeRequest, "req-nr").status == "SUBMITTED"  # 未入账


def test_release_requires_provable_unexecuted_state(env):
    app, factory, ledger, headers = env
    # 调整仍在审批：不得释放（超时≠失败）
    denied = post(app, headers["agent"], "/api/v1/recharge/admin/requests/req-nr/review",
        {"action": "release", "binding_id": "bind-nr", "reason": "长时间未处理"})
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "RECHARGE_RELEASE_EVIDENCE_REQUIRED"
    # 调整被拒：确证未执行 → 释放
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-nr").status = "REJECTED"
    released = post(app, headers["agent"], "/api/v1/recharge/admin/requests/req-nr/review",
        {"action": "release", "binding_id": "bind-nr", "reason": "审批被拒绝，案件可重新绑定"})
    assert released.status_code == 200
    assert released.json()["state"] == "FAILED"
    with factory() as session:
        assert session.get(RechargeRequest, "req-nr").status == "SUBMITTED"


def test_timeline_and_pagination(env):
    app, factory, ledger, headers = env
    # 先触发一次带状态迁移的处置（产生审计事件），再查时间线
    with factory.begin() as session:
        session.get(AdjustmentRequest, "adj-nr").status = "REJECTED"
    released = post(app, headers["agent"], "/api/v1/recharge/admin/requests/req-nr/review",
        {"action": "release", "binding_id": "bind-nr", "reason": "审批被拒绝，案件可重新绑定"})
    assert released.status_code == 200
    timeline = get(app, headers["agent"], "/api/v1/recharge/admin/requests/req-nr/timeline")
    assert timeline.status_code == 200
    assert timeline.json()["request_id"] == "req-nr"
    assert len(timeline.json()["items"]) >= 1
    page = get(app, headers["agent"], "/api/v1/recharge/admin/requests?limit=2")
    assert page.status_code == 200
    body = page.json()
    assert len(body["items"]) == 2 and body["next_cursor"]
    page2 = get(app, headers["agent"], f"/api/v1/recharge/admin/requests?limit=2&cursor={body['next_cursor']}")
    assert page2.status_code == 200
    assert len(page2.json()["items"]) >= 1
    denied = get(app, headers["alice"], "/api/v1/recharge/admin/requests")
    assert denied.status_code == 403
