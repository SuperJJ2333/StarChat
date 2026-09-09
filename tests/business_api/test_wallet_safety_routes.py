"""Application HTTP contract for wallet conversion and production fail-closed."""

from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.api.wallet import create_wallet_router
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers


@pytest.fixture
def wallet_http():
    engine = create_engine("sqlite+pysqlite:///:memory:",
                           connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", jwt_secret="test-" * 8,
                        wallet_conversions_enabled=False)
    app = FastAPI()
    install_error_handlers(app)
    app.include_router(create_wallet_router(settings, factory), prefix="/api/v1")
    now = datetime.now(timezone.utc)
    token = jwt.encode({"sub": "route-user", "iss": settings.jwt_issuer,
                        "iat": now, "exp": now + timedelta(minutes=5)},
                       settings.jwt_secret, algorithm="HS256")
    yield TestClient(app), {"Authorization": f"Bearer {token}"}
    engine.dispose()


def test_conversion_route_requires_authentication(wallet_http):
    client, _ = wallet_http
    response = client.post("/api/v1/wallet/conversions", json={
        "direction": "USDT_TO_CAIBI", "amount": "1.00"},
        headers={"Idempotency-Key": "conversion-1"})
    assert response.status_code == 401


def test_conversion_requires_idempotency_header(wallet_http):
    client, headers = wallet_http
    response = client.post("/api/v1/wallet/conversions", headers=headers,
                           json={"direction": "USDT_TO_CAIBI", "amount": "1.00"})
    assert response.status_code == 422


def test_conversion_rejects_json_numeric_amount(wallet_http):
    client, headers = wallet_http
    response = client.post("/api/v1/wallet/conversions",
                           headers={**headers, "Idempotency-Key": "conversion-1"},
                           json={"direction": "USDT_TO_CAIBI", "amount": 1.0})
    assert response.status_code == 422


def test_disabled_conversion_is_explicit(wallet_http):
    client, headers = wallet_http
    response = client.post("/api/v1/wallet/conversions",
                           headers={**headers, "Idempotency-Key": "conversion-1"},
                           json={"direction": "USDT_TO_CAIBI", "amount": "1.00"})
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "WALLET_CONVERSION_DISABLED"


def test_configuration_exposes_safe_conversion_state(wallet_http):
    client, headers = wallet_http
    response = client.get("/api/v1/wallet/config", headers=headers)
    assert response.status_code == 200
    assert response.json()["conversion_enabled"] is False
    assert response.json()["confirmation_threshold"] >= 20


def test_balances_include_available_held_and_points(wallet_http):
    client, headers = wallet_http
    response = client.get("/api/v1/wallet/balances/me", headers=headers)
    assert response.status_code == 200
    assert response.json()["usdt_available"] == "0.000000"
    assert response.json()["usdt_held"] == "0.000000"
    assert response.json()["caibi_available"] == "0.00"
