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
    return Settings(**values)


@pytest.mark.asyncio
async def test_live_health_exposes_product_identity() -> None:
    app = create_app(_settings())

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/api/v1/health/live")

    assert response.status_code == 200
    assert response.json() == {"ok": True, "service": "六合通 Business API"}


def test_production_requires_jwt_and_totp_secrets() -> None:
    with pytest.raises(ValueError, match="production requires"):
        _settings(environment="production")


def test_production_accepts_required_secrets() -> None:
    settings = _settings(
        environment="production",
        jwt_secret="test-jwt-secret",
        totp_issuer="六合通",
    )

    assert settings.environment == "production"
