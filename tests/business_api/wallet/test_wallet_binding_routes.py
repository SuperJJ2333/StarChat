from datetime import datetime, timezone

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, func
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import install_error_handlers
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService
from app.modules.wallet.binding_models import WalletBindingChallenge


def test_binding_routes_require_session_and_report_missing_readiness():
    from app.api.wallet_binding import create_wallet_binding_router
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(_env_file=None, environment="test", jwt_secret="binding-route-test-" * 3,
                        wallet_binding_domain="wallet.example.invalid")
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id="binding-user", username="binding-user", username_normalized="binding-user",
            email="binding@example.invalid", email_normalized="binding@example.invalid", password_hash="fixture",
            status=AccountStatus.ACTIVE, created_at=now, updated_at=now))
    pair = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer).issue_pair(
        user_id="binding-user", device_key="binding-device", display_name="fixture")
    app = FastAPI(); install_error_handlers(app)
    app.include_router(create_wallet_binding_router(settings, factory))
    client = TestClient(app)
    assert client.get("/binding").status_code == 401
    headers = {"Authorization": "Bearer " + pair.access_token, "Idempotency-Key": "bind-request"}
    response = client.get("/binding", headers=headers)
    assert response.status_code == 200
    assert response.json()["status"] == "UNBOUND"
    assert response.json()["binding_enabled"] is False
    assert set(response.json()["unavailable_dependencies"]) == {"MFA", "ACCOUNT_PERMISSIONS", "INDEPENDENT_FINALITY"}
    assert response.headers["cache-control"] == "no-store"
    response = client.post("/binding/challenges", headers=headers,
        json={"address": "invalid-unreachable-fixture", "expected_version": 0})
    assert response.status_code == 503
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(WalletBindingChallenge)) == 0
    engine.dispose()
