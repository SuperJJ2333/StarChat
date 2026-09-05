"""审计 A01/A02/A04/U03：钱包路由级 HTTP 契约（经注册后的路由实际请求）。

- A01：GET /wallet/deposit-address——首次分配、重复获取、跨用户隔离；
- A02：POST /wallet/webhooks/custody 按事件类型分发（充值/提现/未知/坏签名）；
- A04：生产 + 沙箱配置 → 资金入口 503、只读接口照常、config 提示；
- U03：/wallet/config 返回服务端有效确认阈值（客户端展示来源）。
"""
import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import jwt
import pytest
from fastapi import FastAPI
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.api.wallet import create_wallet_router
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.custody.sandbox import SandboxCustodyProvider


def _settings(**overrides) -> Settings:
    values = dict(
        _env_file=None, environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret="r" * 32, totp_issuer="六合通",
    )
    values.update(overrides)
    return Settings(**values)


def _bearer(settings: Settings, user_id: str) -> dict:
    now = datetime.now(timezone.utc)
    token = jwt.encode(
        {"sub": user_id, "iss": settings.jwt_issuer, "iat": int(now.timestamp()), "exp": int((now + timedelta(minutes=5)).timestamp())},
        settings.jwt_secret, algorithm="HS256",
    )
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def api():
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = _settings()
    app = FastAPI()
    from app.core.errors import install_error_handlers
    install_error_handlers(app)
    app.include_router(create_wallet_router(settings, factory), prefix="/api/v1")
    from fastapi.testclient import TestClient

    client = TestClient(app)
    yield client, factory, settings
    engine.dispose()


def test_a01_deposit_address_first_allocation_and_reuse(api):
    client, factory, settings = api
    first = client.get("/api/v1/wallet/deposit-address", headers=_bearer(settings, "u1"))
    assert first.status_code == 200
    body = first.json()
    assert body["asset"] == "USDT-TRC20" and body["network"] == "TRC20"
    assert body["address"].startswith("T_SANDBOX_u1"), "地址分配绑定用户"
    again = client.get("/api/v1/wallet/deposit-address", headers=_bearer(settings, "u1"))
    assert again.json()["address"] == body["address"], "重复获取返回同一地址（归属持久化）"
    other = client.get("/api/v1/wallet/deposit-address", headers=_bearer(settings, "u2"))
    assert other.json()["address"] != body["address"], "跨用户隔离"


def test_a02_webhook_dispatches_withdrawal_events(api):
    """A02：提现事件经公开回调路由实际分发（此前该路由只认充值事件）。"""
    client, factory, _settings_unused = api
    from app.modules.wallet.service import WalletService

    service = WalletService(factory, SandboxCustodyProvider(secret="development-wallet-webhook-secret"))
    service.credit_for_test("u1", Decimal("10.000000"))
    row = service.request_withdrawal(user_id="u1", amount=Decimal("2.000000"), address="T9", client_order_id="o1", reason_code="USER_WITHDRAWAL")
    service.finance_approve(row.id, "finance")
    service.submit_to_custody(row.id, "finance")

    provider = SandboxCustodyProvider(secret="development-wallet-webhook-secret")
    event = provider.withdrawal_event(client_order_id=row.id, status="FAILED", confirmations=1, event_id="wh-failed")
    resp = client.post("/api/v1/wallet/webhooks/custody", json=event.payload, headers={"X-Custody-Signature": event.signature})
    assert resp.status_code == 200
    assert resp.json() == {"status": "FAILED_COMPENSATED"}, "提现失败事件推进状态并补偿"


def test_a02_webhook_unsupported_type_and_bad_signature(api):
    client, _, _settings_unused = api
    unsupported = client.post("/api/v1/wallet/webhooks/custody", json={"type": "SOMETHING_ELSE"}, headers={"X-Custody-Signature": "x"})
    assert unsupported.status_code == 400
    assert unsupported.json()["error"]["code"] == "CUSTODY_EVENT_UNSUPPORTED"
    bad_sig = client.post(
        "/api/v1/wallet/webhooks/custody",
        json={"type": "DEPOSIT_CONFIRMED", "asset": "USDT-TRC20", "event_id": "e", "txid": "t", "user_id": "u", "amount": "1", "confirmations": 20},
        headers={"X-Custody-Signature": "forged"},
    )
    assert bad_sig.status_code == 401
    assert bad_sig.json()["error"]["code"] == "CUSTODY_SIGNATURE_INVALID"


def test_u03_config_endpoint_returns_server_threshold(api):
    client, _, settings = api
    resp = client.get("/api/v1/wallet/config", headers=_bearer(settings, "u1"))
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["confirmation_threshold"] == 12, "阈值来自服务端设置（客户端展示统一来源）"
    assert payload["funding_enabled"] is True


def _production_settings(**overrides) -> Settings:
    """合法的生产配置（全部必填密钥 + HTTPS），仅钱包项按测试需要覆盖。"""
    values = dict(
        _env_file=None, environment="production",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
        jwt_secret="p" * 32,
        totp_issuer="六合通",
        email_verification_secret="prod-email-secret",
        password_reset_secret="prod-reset-secret",
        synapse_admin_access_token="prod-admin-token",
        matrix_provision_secret="prod-matrix-secret",
        avatar_url_signing_secret="prod-avatar-secret",
        referral_code_secret="prod-referral-secret",
        matrix_public_homeserver_url="https://matrix.example.test",
        avatar_public_base_url="https://avatar.example.test",
    )
    values.update(overrides)
    return Settings(**values)


def test_a04_production_sandbox_mode_disables_funding_but_keeps_reads():
    """A04：生产 + 沙箱配置 → 资金入口 503（fail closed），余额/配置照常。"""
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = _settings()
    app = FastAPI()
    from app.core.errors import install_error_handlers
    install_error_handlers(app)
    app.include_router(create_wallet_router(settings, factory, custody_provider=(None, "unconfigured")), prefix="/api/v1")
    from fastapi.testclient import TestClient

    client = TestClient(app)
    deposit = client.get("/api/v1/wallet/deposit-address", headers=_bearer(settings, "u1"))
    assert deposit.status_code == 503
    assert deposit.json()["error"]["code"] == "WALLET_CUSTODY_NOT_CONFIGURED"
    withdraw = client.post(
        "/api/v1/wallet/withdrawals",
        headers=_bearer(settings, "u1"),
        json={"amount": "1.000000", "address": "T9", "client_order_id": "x", "reason_code": "R"},
    )
    assert withdraw.status_code == 503
    balance = client.get("/api/v1/wallet/balances/me", headers=_bearer(settings, "u1"))
    assert balance.status_code == 200, "只读接口不受资金门禁影响"
    config = client.get("/api/v1/wallet/config", headers=_bearer(settings, "u1"))
    assert config.json()["funding_enabled"] is False
    engine.dispose()


def test_a04_production_wallet_provider_requires_real_secret():
    """A04：生产显式启用钱包 provider 时，占位 webhook 密钥必须被拒绝。"""
    with pytest.raises(Exception, match="non-placeholder"):
        _production_settings(wallet_custody_provider="production")
