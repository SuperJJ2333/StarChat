from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine
import httpx

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
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
        event_type="identity.matrix.provision.requested",
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


def test_synapse_gateway_treats_existing_mxid_as_success() -> None:
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
    assert [request.method for request in requests] == ["PUT"]


def test_synapse_gateway_uploads_private_avatar_then_sets_mxc_profile() -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == "/_matrix/media/v3/upload":
            return httpx.Response(
                200, json={"content_uri": "mxc://matrix.localhost/avatar-1"}
            )
        return httpx.Response(200, json={})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.localhost",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    mxc_uri = gateway.upload_profile_media(b"private-avatar", "image/png")
    gateway.set_user_profile(
        "@alice:matrix.localhost",
        display_name="Alice Chen",
        avatar_url=mxc_uri,
    )

    assert mxc_uri == "mxc://matrix.localhost/avatar-1"
    assert [request.method for request in requests] == ["POST", "PUT"]
    assert requests[0].headers["Content-Type"] == "image/png"
    assert requests[0].content == b"private-avatar"
    assert requests[1].url.path.endswith(
        "/_synapse/admin/v2/users/@alice:matrix.localhost"
    )
    assert requests[1].read().decode("utf-8") == (
        '{"displayname":"Alice Chen","avatar_url":'
        '"mxc://matrix.localhost/avatar-1"}'
    )


def test_synapse_gateway_queries_same_mxid_after_unknown_put_timeout() -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.method == "PUT":
            raise httpx.ReadTimeout("unknown create result", request=request)
        return httpx.Response(200, json={"name": "@alice:matrix.localhost"})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.localhost",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    assert gateway.ensure_user("alice", "generated-password") == "@alice:matrix.localhost"
    assert [request.method for request in requests] == ["PUT", "GET"]
    assert requests[0].url == requests[1].url


def test_synapse_gateway_reports_unknown_result_only_after_lookup() -> None:
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.method == "PUT":
            raise httpx.ReadTimeout("unknown create result", request=request)
        return httpx.Response(404, json={"errcode": "M_NOT_FOUND"})

    gateway = SynapseMatrixAdminGateway(
        homeserver_url="http://synapse:8008",
        server_name="matrix.localhost",
        admin_access_token="admin-token",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
    )

    with pytest.raises(AppError) as exc_info:
        gateway.ensure_user("alice", "generated-password")

    assert exc_info.value.code == "MATRIX_PROVISION_RESULT_UNKNOWN"
    assert [request.method for request in requests] == ["PUT", "GET"]


def test_matrix_provisioning_rejects_event_identity_mismatch() -> None:
    engine = create_engine("sqlite+pysqlite:///:memory:", connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    gateway = FakeMatrixGateway()
    task = MatrixProvisionTask(
        factory,
        gateway=gateway,
        credential_codec=MatrixCredentialCodec(b"test-matrix-provision-secret"),
    )

    with pytest.raises(AppError) as exc_info:
        task(
            OutboxMessage(
                id="event-mismatch",
                topic="identity.matrix",
                event_type="identity.matrix.provision.requested",
                aggregate_type="user",
                aggregate_id="user-1",
                payload={"user_id": "user-2"},
                headers={},
                attempt_count=1,
            )
        )

    assert exc_info.value.code == "MATRIX_EVENT_INVALID"
    assert gateway.calls == []
    engine.dispose()
