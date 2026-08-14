from datetime import datetime, timezone
import json
import logging
from pathlib import Path

import httpx
import pytest
from sqlalchemy import create_engine, func, select

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.integrations.matrix_admin import SynapseMatrixAdminGateway
from app.main import create_app
from app.modules.audit.models import AuditEvent
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService


NOW = datetime.now(timezone.utc)
JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
ROOT = Path(__file__).parents[3]


class RecordingMatrixGateway:
    def __init__(self, token: str = "one-time-matrix-token") -> None:
        self.token = token
        self.calls: list[tuple[str, int]] = []

    def issue_login_token(self, matrix_user_id: str, expires_in: int) -> str:
        self.calls.append((matrix_user_id, expires_in))
        return self.token


class RejectingMatrixGateway:
    def issue_login_token(self, matrix_user_id: str, expires_in: int) -> str:
        raise AppError(
            code="MATRIX_LOGIN_TOKEN_FAILED",
            message="Matrix 登录令牌签发失败",
            status_code=502,
        )


def _components(gateway=None):
    engine = create_engine(
        "sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        matrix_public_homeserver_url="https://matrix.example.test",
        matrix_login_token_expires_in=60,
    )
    gateway = gateway or RecordingMatrixGateway()
    app = create_app(settings, session_factory=factory, matrix_gateway=gateway)
    return engine, factory, app, gateway


def _add_user(factory, user_id: str, *, status=AccountStatus.ACTIVE, mxid=None) -> None:
    with factory.begin() as session:
        session.add(
            User(
                id=user_id,
                username=user_id,
                username_normalized=user_id,
                email=f"{user_id}@example.test",
                email_normalized=f"{user_id}@example.test",
                password_hash="hash",
                status=status,
                matrix_user_id=mxid,
                email_verified_at=NOW,
                created_at=NOW,
                updated_at=NOW,
            )
        )


def _access_token(factory, user_id: str) -> str:
    return TokenService(
        factory,
        jwt_secret=JWT_SECRET,
        jwt_issuer="liuhetong",
        now_factory=lambda: NOW,
    ).issue_pair(
        user_id=user_id,
        device_key=f"device-{user_id}",
        display_name="Integration device",
    ).access_token


@pytest.mark.asyncio
async def test_matrix_login_token_is_bound_to_authenticated_business_subject(
    caplog,
) -> None:
    engine, factory, app, gateway = _components()
    _add_user(factory, "user-1", mxid="@alice:matrix.example.test")
    _add_user(factory, "user-2", mxid="@bob:matrix.example.test")
    access_token = _access_token(factory, "user-1")
    with factory() as session:
        outbox_before = session.scalar(select(func.count()).select_from(OutboxEvent))

    caplog.set_level(logging.DEBUG)
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/api/v1/auth/matrix-login-token",
            headers={"Authorization": f"Bearer {access_token}"},
        )

    assert response.status_code == 200
    assert response.json() == {
        "login_token": "one-time-matrix-token",
        "homeserver": "https://matrix.example.test",
        "expires_in": 60,
    }
    assert gateway.calls == [("@alice:matrix.example.test", 60)]
    assert "one-time-matrix-token" not in caplog.text
    with factory() as session:
        assert session.scalar(select(func.count()).select_from(OutboxEvent)) == outbox_before
        audit = session.scalar(
            select(AuditEvent).where(
                AuditEvent.action == "identity.matrix.login_token.issued"
            )
        )
        assert audit.actor_id == audit.subject_id == "user-1"
        assert audit.result == "SUCCESS"
        assert audit.before_data is None and audit.after_data is None
        assert "one-time-matrix-token" not in json.dumps(audit.__dict__, default=str)
    engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("authorization", "expected_code"),
    [(None, "AUTH_REQUIRED"), ("Bearer invalid", "ACCESS_TOKEN_INVALID")],
)
async def test_matrix_login_token_requires_valid_business_access_token(
    authorization,
    expected_code,
) -> None:
    engine, _, app, gateway = _components()
    headers = {} if authorization is None else {"Authorization": authorization}

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/api/v1/auth/matrix-login-token", headers=headers
        )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == expected_code
    assert gateway.calls == []
    engine.dispose()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "mxid", "expected_code"),
    [
        (AccountStatus.PENDING_MATRIX, None, "MATRIX_ACCOUNT_NOT_ACTIVE"),
        (AccountStatus.ACTIVE, None, "MATRIX_IDENTITY_UNAVAILABLE"),
    ],
)
async def test_matrix_login_token_rejects_unready_business_identity(
    status,
    mxid,
    expected_code,
) -> None:
    engine, factory, app, gateway = _components()
    _add_user(factory, "user-1", status=status, mxid=mxid)
    if status != AccountStatus.ACTIVE:
        # A signed access token can outlive a later account-state transition.
        with factory.begin() as session:
            session.get(User, "user-1").status = AccountStatus.ACTIVE
        access_token = _access_token(factory, "user-1")
        with factory.begin() as session:
            session.get(User, "user-1").status = status
    else:
        access_token = _access_token(factory, "user-1")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/api/v1/auth/matrix-login-token",
            headers={"Authorization": f"Bearer {access_token}"},
        )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == expected_code
    assert gateway.calls == []
    engine.dispose()


@pytest.mark.asyncio
async def test_matrix_login_token_records_sanitized_synapse_failure() -> None:
    engine, factory, app, _ = _components(RejectingMatrixGateway())
    _add_user(factory, "user-1", mxid="@alice:matrix.example.test")
    access_token = _access_token(factory, "user-1")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://test"
    ) as client:
        response = await client.post(
            "/api/v1/auth/matrix-login-token",
            headers={"Authorization": f"Bearer {access_token}"},
        )

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "MATRIX_LOGIN_TOKEN_FAILED"
    with factory() as session:
        audit = session.scalar(
            select(AuditEvent).where(
                AuditEvent.action == "identity.matrix.login_token.issued"
            )
        )
        assert audit.actor_id == "user-1"
        assert audit.result == "FAILURE"
        assert audit.reason_code == "MATRIX_LOGIN_TOKEN_FAILED"
        assert audit.before_data is None and audit.after_data is None
    engine.dispose()


def test_synapse_login_token_gateway_uses_encoded_mxid_and_short_expiry() -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path.endswith("/login/get_token"):
            return httpx.Response(
                200,
                json={"login_token": "synapse-once", "expires_in": 60},
            )
        return httpx.Response(200, json={"access_token": "short-lived-puppet"})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.example.test",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
        now_factory=lambda: NOW,
    )

    assert gateway.issue_login_token("@alice:matrix.example.test", 60) == "synapse-once"
    admin_request, login_token_request = requests
    assert admin_request.method == "POST"
    assert admin_request.url.path.endswith(
        "/_synapse/admin/v1/users/@alice:matrix.example.test/login"
    )
    assert admin_request.headers["Authorization"] == "Bearer admin-token"
    assert json.loads(admin_request.content) == {
        "valid_until_ms": int(NOW.timestamp() * 1000) + 60_000
    }
    assert login_token_request.method == "POST"
    assert login_token_request.url.path.endswith("/_matrix/client/v1/login/get_token")
    assert (
        login_token_request.headers["Authorization"]
        == "Bearer short-lived-puppet"
    )
    assert json.loads(login_token_request.content) == {}


@pytest.mark.parametrize(
    "response",
    [
        httpx.Response(403, json={"errcode": "M_FORBIDDEN"}),
        httpx.Response(200, json={}),
    ],
)
def test_synapse_login_token_gateway_uses_stable_failure_code(response) -> None:
    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.example.test",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(lambda _: response)),
        now_factory=lambda: NOW,
    )

    with pytest.raises(AppError) as exc_info:
        gateway.issue_login_token("@alice:matrix.example.test", 60)

    assert exc_info.value.code == "MATRIX_LOGIN_TOKEN_FAILED"


def test_synapse_login_token_gateway_redacts_second_exchange_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/login/get_token"):
            return httpx.Response(403, json={"error": "sensitive upstream detail"})
        return httpx.Response(200, json={"access_token": "short-lived-puppet"})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.example.test",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
        now_factory=lambda: NOW,
    )

    with pytest.raises(AppError) as exc_info:
        gateway.issue_login_token("@alice:matrix.example.test", 60)

    assert exc_info.value.code == "MATRIX_LOGIN_TOKEN_FAILED"
    assert "sensitive upstream detail" not in str(exc_info.value)
    assert "short-lived-puppet" not in str(exc_info.value)


def test_synapse_enables_short_lived_existing_session_login_tokens() -> None:
    template = (ROOT / "infra/synapse/homeserver.yaml.template").read_text(
        encoding="utf-8"
    )

    assert "login_via_existing_session:" in template
    assert "  enabled: true" in template
    assert "  require_ui_auth: false" in template
    assert "  token_timeout: 1m" in template


def test_business_and_synapse_login_token_expiry_cannot_drift() -> None:
    with pytest.raises(ValueError):
        Settings(_env_file=None, matrix_login_token_expires_in=120)
