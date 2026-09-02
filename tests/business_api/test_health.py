from httpx import ASGITransport, AsyncClient
import pytest

from app.core.config import Settings
from app.main import create_app


def _settings(**overrides) -> Settings:
    values = {
        "database_url": "sqlite+pysqlite:///:memory:",
        "redis_url": "redis://localhost:6379/15",
        "environment": "test",
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)


@pytest.mark.asyncio
async def test_live_health_exposes_product_identity() -> None:
    app = create_app(_settings())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/health/live")

    assert response.status_code == 200
    assert response.json() == {"ok": True, "service": "六合通 Business API"}


@pytest.mark.asyncio
async def test_ready_health_checks_database() -> None:
    app = create_app(_settings())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/health/ready")

    assert response.status_code == 200
    assert response.json() == {
        "ok": True,
        "service": "六合通 Business API",
        "database": "ready",
    }


def test_production_requires_jwt_and_totp_secrets() -> None:
    with pytest.raises(ValueError, match="production requires"):
        _settings(environment="production")


def test_production_accepts_required_secrets() -> None:
    settings = _settings(
        environment="production",
        jwt_secret="test-jwt-secret",
        totp_issuer="六合通",
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        synapse_admin_access_token="test-synapse-admin-access-token",
        matrix_provision_secret="test-matrix-provision-secret",
        avatar_url_signing_secret="test-avatar-url-signing-secret",
        referral_code_secret="test-referral-code-secret",
        matrix_public_homeserver_url="https://matrix.example.test",
        avatar_public_base_url="https://api.example.test",
    )

    assert settings.environment == "production"


def test_production_rejects_public_matrix_provision_secret() -> None:
    with pytest.raises(ValueError, match="MATRIX_PROVISION_SECRET"):
        _settings(
            environment="production",
            jwt_secret="test-jwt-secret",
            totp_issuer="六合通",
            email_verification_secret="test-email-verification-secret",
            password_reset_secret="test-password-reset-secret",
            synapse_admin_access_token="test-synapse-admin-access-token",
            matrix_provision_secret="development-matrix-provision-secret",
            avatar_url_signing_secret="test-avatar-url-signing-secret",
            referral_code_secret="test-referral-code-secret",
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("jwt_secret", "change-this-business-jwt-secret"),
        ("email_verification_secret", "change-this-email-verification-secret"),
        ("password_reset_secret", "change-this-password-reset-secret"),
        ("synapse_admin_access_token", "change-this-synapse-admin-token"),
        ("matrix_provision_secret", "change-this-matrix-provision-secret"),
        ("avatar_url_signing_secret", "change-this-avatar-url-signing-secret"),
        ("referral_code_secret", "change-this-referral-code-secret"),
    ],
)
def test_production_rejects_public_placeholder_secrets(field, value) -> None:
    secure = "s" * 48
    values = {
        "environment": "production",
        "jwt_secret": secure,
        "totp_issuer": "六合通",
        "email_verification_secret": secure,
        "password_reset_secret": secure,
        "synapse_admin_access_token": secure,
        "matrix_provision_secret": secure,
        "avatar_url_signing_secret": secure,
        "referral_code_secret": secure,
        "matrix_public_homeserver_url": "https://matrix.example.test",
        "avatar_public_base_url": "https://api.example.test",
        field: value,
    }

    with pytest.raises(ValueError, match="production secrets"):
        _settings(**values)


def test_production_rejects_cleartext_public_urls() -> None:
    with pytest.raises(ValueError, match="HTTPS"):
        _settings(
            environment="production",
            jwt_secret="test-jwt-secret",
            totp_issuer="六合通",
            email_verification_secret="test-email-verification-secret",
            password_reset_secret="test-password-reset-secret",
            synapse_admin_access_token="test-synapse-admin-access-token",
            matrix_provision_secret="test-matrix-provision-secret",
            avatar_url_signing_secret="test-avatar-url-signing-secret",
            referral_code_secret="test-referral-code-secret",
        )


def test_unscoped_database_url_environment_variable_is_ignored(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql://legacy/other-product")

    settings = Settings(_env_file=None)

    assert settings.database_url.startswith("postgresql+psycopg://liuhetong:")
