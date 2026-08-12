from datetime import datetime, timezone

from sqlalchemy import create_engine
import httpx

from app.core.database import Base, create_session_factory
from app.core.outbox import OutboxMessage
from app.integrations.matrix_admin import MatrixCredentialCodec, SynapseMatrixAdminGateway
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.provisioning import MatrixProvisionTask


class FakeMatrixGateway:
    def __init__(self) -> None:
        self.calls = []

    def ensure_user(self, localpart: str, password: str) -> str:
        self.calls.append((localpart, password))
        return f"@{localpart}:matrix.localhost"


def test_matrix_provisioning_activates_verified_user_idempotently() -> None:
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime(2026, 8, 12, 8, 0, tzinfo=timezone.utc)
    with factory.begin() as session:
        session.add(
            User(
                id="user-1",
                username="Alice",
                username_normalized="alice",
                email="alice@example.com",
                email_normalized="alice@example.com",
                password_hash="hash",
                status=AccountStatus.PENDING_MATRIX,
                email_verified_at=now,
                created_at=now,
                updated_at=now,
            )
        )

    gateway = FakeMatrixGateway()
    task = MatrixProvisionTask(
        factory,
        gateway=gateway,
        credential_codec=MatrixCredentialCodec(b"test-matrix-provision-secret"),
        now_factory=lambda: now,
    )
    message = OutboxMessage(
        id="event-1",
        topic="identity.matrix",
        event_type="identity.matrix_provision.requested",
        aggregate_type="user",
        aggregate_id="user-1",
        payload={"user_id": "user-1"},
        headers={},
        attempt_count=1,
    )

    task(message)
    task(message)

    with factory() as session:
        user = session.get(User, "user-1")
        assert user.status == AccountStatus.ACTIVE
        assert user.matrix_user_id == "@alice:matrix.localhost"
    assert len(gateway.calls) == 1
    localpart, password = gateway.calls[0]
    assert localpart == "alice"
    assert len(password) >= 32
    engine.dispose()


def test_synapse_gateway_uses_idempotent_admin_put() -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={"name": "@alice:matrix.localhost"})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.localhost",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    assert gateway.ensure_user("alice", "generated-password") == "@alice:matrix.localhost"
    request = requests[0]
    assert request.method == "PUT"
    assert request.headers["Authorization"] == "Bearer admin-token"
    assert request.url.path.endswith("/_synapse/admin/v2/users/@alice:matrix.localhost")
