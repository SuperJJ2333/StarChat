"""客服点钻派发：储备策略接线与错误细分。

生产以 BUSINESS_WALLET_RESERVE_POLICY=manual_liquidity 运行，但 admin 派发路径的
LedgerService 曾硬编码 full_backing，导致储备缺口（记录型策略）被误报为
"点钻发放请求无效"。这里锁定两件事：
1. admin 派发遵循 settings.wallet_reserve_policy；
2. 每类 ValueError 都有可区分的错误码与可读文案，不再笼统报"请求无效"。
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import runpy
from unittest.mock import patch

import pytest

from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool
from httpx import AsyncClient, ASGITransport

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus, RoleCode
from app.modules.identity.models import User, UserRole
from app.modules.identity.tokens import TokenService
from app.modules.ledger.models import LedgerEntry
from app.modules.ledger.reserve import RedeemabilityReserve
from app.modules.fx.models import FxRate

GRANT = {"user_id": "u1", "amount": "88.00", "reason_code": "SUPPORT_CAIBI_GRANT"}


def build_app(*, reserve_policy, observed_at=None, pending_payouts=0):
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    if observed_at is None:
        observed_at = now
    with factory.begin() as session:
        session.add_all([
            FxRate(pair='USD/CNY', rate=Decimal('7.12'), fetched_at=now,
                expires_at=now+timedelta(hours=1), fetch_state='idle'),
            User(id="admin-1", username="admin", username_normalized="admin", email="a@x.com", email_normalized="a@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            User(id="u1", username="user", username_normalized="user", email="u@x.com", email_normalized="u@x.com", password_hash="x", status=AccountStatus.ACTIVE, created_at=now, updated_at=now),
            UserRole(id="r1", user_id="admin-1", role_code=RoleCode.SUPER_ADMIN, assigned_by="bootstrap", assigned_at=now),
            UserRole(id="r2", user_id="u1", role_code=RoleCode.SUPPORT_AGENT, assigned_by="admin-1", assigned_at=now),
            # 复刻生产缺口形态：储备 40 USDT 远小于负债，仅 manual_liquidity 允许继续发行。
            RedeemabilityReserve(id="global", eligible_usdt=Decimal("40.000000"), usdt_liability=Decimal("58.910000"),
                version=1, pending_payouts=pending_payouts, outgoing_restricted=False, observed_at=observed_at),
        ])
    settings = Settings(_env_file=None, environment="test", database_url="sqlite+pysqlite:///:memory:", jwt_secret="test-jwt-secret-at-least-thirty-two-bytes")
    settings.wallet_reserve_policy = reserve_policy
    app = create_app(settings, session_factory=factory)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer, require_session_claims=False)
    return app, tokens.issue_admin_pair(user_id="admin-1", display_name="admin").access_token


async def post_grant(app, token, idempotency_key, payload=None):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        return await client.post("/api/v1/admin/finance/adjustments", json=payload or GRANT,
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": idempotency_key})


@pytest.mark.asyncio
async def test_fresh_reserve_fixture_survives_slow_test_collection():
    class CollectionClock(datetime):
        @classmethod
        def now(cls, tz=None):
            return datetime.now(tz) - timedelta(hours=1)

    # Load only this test module as if collection occurred an hour ago, then
    # restore its runtime clock before exercising the real API freshness gate.
    with patch('datetime.datetime', CollectionClock):
        collected = runpy.run_path(__file__)
    build = collected['build_app']
    build.__globals__['datetime'] = datetime
    app, token = build(reserve_policy='manual_liquidity')
    response = await post_grant(app, token, 'grant-after-slow-collection')
    assert response.status_code == 201, response.json()


@pytest.mark.asyncio
async def test_manual_liquidity_policy_allows_grant_despite_backing_deficit():
    app, token = build_app(reserve_policy="manual_liquidity")
    response = await post_grant(app, token, "grant-manual-1")
    assert response.status_code == 201
    assert response.json()["amount"] == "88.00"
    with app.state.session_factory() as session:
        assert session.scalar(select(LedgerEntry).where(LedgerEntry.account_id == "u1", LedgerEntry.amount == 88)) is not None


@pytest.mark.asyncio
async def test_full_backing_deficit_reports_reserve_coverage_error():
    app, token = build_app(reserve_policy="full_backing")
    response = await post_grant(app, token, "grant-full-1")
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "RESERVE_COVERAGE_INSUFFICIENT"
    assert "储备覆盖不足" in response.json()["error"]["message"]


@pytest.mark.asyncio
async def test_manual_liquidity_stale_evidence_reports_stale_error():
    app, token = build_app(reserve_policy="manual_liquidity", observed_at=datetime.now(timezone.utc) - timedelta(minutes=10))
    response = await post_grant(app, token, "grant-stale-1")
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "RESERVE_EVIDENCE_STALE"
    assert "储备证据" in response.json()["error"]["message"]


@pytest.mark.asyncio
async def test_unresolved_payouts_report_pending_error():
    app, token = build_app(reserve_policy="manual_liquidity", pending_payouts=1)
    response = await post_grant(app, token, "grant-pending-1")
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "RESERVE_PAYOUT_PENDING"
    assert "未决赔付" in response.json()["error"]["message"]


@pytest.mark.asyncio
async def test_idempotent_payload_conflict_reports_conflict_error():
    app, token = build_app(reserve_policy="manual_liquidity")
    first = await post_grant(app, token, "grant-conflict-1")
    conflict = await post_grant(app, token, "grant-conflict-1", payload={**GRANT, "amount": "99.00"})
    assert first.status_code == 201
    assert conflict.status_code == 422
    assert conflict.json()["error"]["code"] == "IDEMPOTENCY_PAYLOAD_CONFLICT"
    assert "重新填写" in conflict.json()["error"]["message"]


@pytest.mark.asyncio
async def test_approval_execute_path_follows_the_same_reserve_policy():
    """审批执行（POST /ledger/adjustments/{id}/execute）与直发共用同一策略口径。"""
    app, token = build_app(reserve_policy="manual_liquidity")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        policy = await client.put("/api/v1/ledger/adjustment-policies/admin-1",
            json={"per_transaction": "100.00", "per_day": "1000.00", "allowed_users": ["u1"]},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "exec-policy-1"})
        submitted = await client.post("/api/v1/ledger/adjustments",
            json={"user_id": "u1", "amount": "12.00", "reason_code": "SUPPORT_CAIBI_GRANT"},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "exec-submit-1"})
    assert policy.status_code == 204
    assert submitted.status_code == 201
    request_id = submitted.json()["id"]
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        approved = await client.post(f"/api/v1/ledger/adjustments/{request_id}/admin-review", json={"approve": True},
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "exec-approve-1"})
        executed = await client.post(f"/api/v1/ledger/adjustments/{request_id}/execute",
            headers={"Authorization": f"Bearer {token}", "Idempotency-Key": "exec-run-1"})
    assert approved.status_code == 200
    assert executed.status_code == 200
    assert executed.json()["status"] == "EXECUTED"
    with app.state.session_factory() as session:
        assert session.scalar(select(LedgerEntry).where(LedgerEntry.account_id == "u1", LedgerEntry.amount == 12)) is not None
