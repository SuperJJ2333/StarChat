"""Real ASGI routes must not park their event loop in synchronous blob I/O."""

from __future__ import annotations

import asyncio
import base64
from datetime import datetime, timezone
import errno
import hashlib
from io import BytesIO
from pathlib import Path
import threading

import anyio
from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import Settings
from app.core.database import Base
from app.integrations.media_blob_storage import S3BlobBackend
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.profile import ProfileService
from app.modules.identity.tokens import TokenService
from app.modules.media.domain import DigestKind, MediaKind, VisibilityTier
from app.modules.media.repository import IngestRequest, MediaRepository


class StorageGate:
    """A watchdog prevents the deliberately broken route from hanging the test."""

    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.finished = threading.Event()

    def wait(self):
        self.entered.set()
        self.release.wait(timeout=1.0)
        self.finished.set()


class S3Transport:
    """Only the external S3 transport is replaced; validation stays production code."""

    def __init__(self):
        self.objects = {}
        self.gate = None
        self.operation = "get"
        self.bodies = []
        self.failure = None
        self.bad_checksum = False

    def block(self, operation):
        if self.gate is not None and operation == self.operation:
            self.gate.wait()
        if self.failure is not None:
            raise self.failure

    def put_object(self, **values):
        self.block("put")
        self.objects[values["Key"]] = values["Body"]

    def get_object(self, **values):
        transport = self

        class Body(BytesIO):
            def __init__(self, content):
                super().__init__(content)
                self.owner_thread = threading.get_ident()

            def read(self, size=-1):
                assert threading.get_ident() == self.owner_thread
                transport.block("get")
                return super().read(size)

            def close(self):
                assert threading.get_ident() == self.owner_thread
                super().close()

        content = self.objects[values["Key"]]
        body = Body(content)
        self.bodies.append(body)
        return {
            "Body": body,
            "ContentLength": len(content),
            "ChecksumSHA256": "invalid" if self.bad_checksum else base64.b64encode(
                hashlib.sha256(content).digest()).decode(),
            "ChecksumType": "FULL_OBJECT",
        }

    def delete_object(self, **values):
        self.block("delete")
        self.objects.pop(values["Key"], None)


@pytest.fixture()
def media_io_env(tmp_path):
    sessions = []

    class OwnedSession(Session):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.owner_thread = threading.get_ident()
            self.was_closed = False
            sessions.append(self)

        def close(self):
            assert threading.get_ident() == self.owner_thread
            self.was_closed = True
            super().close()

    @event.listens_for(OwnedSession, "do_orm_execute")
    def check_session_thread(state):
        assert threading.get_ident() == state.session.owner_thread

    # Independent connections, unlike StaticPool's shared connection, let the
    # concurrent request tests detect application races without SQLite fixture races.
    engine = create_engine(f"sqlite+pysqlite:///{tmp_path / 'media.db'}")
    Base.metadata.create_all(engine)
    factory = sessionmaker(engine, class_=OwnedSession, expire_on_commit=False)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(id="user-a", username="usera", username_normalized="usera",
            email="usera@example.com", email_normalized="usera@example.com",
            password_hash="hash", status=AccountStatus.ACTIVE,
            email_verified_at=now, created_at=now, updated_at=now))
    transport = S3Transport()
    backend = S3BlobBackend(bucket="test-bucket", region="ap-east-1", client=transport)
    storage = LocalPrivateObjectStorage(root=str(tmp_path / "bytes"), backend=backend,
        signing_secret="test-media-signing-secret-32-bytes", public_base_url="http://test")
    settings = Settings(_env_file=None, environment="test",
        database_url="sqlite+pysqlite:///:memory:", redis_url="redis://unused",
        jwt_secret="test-jwt-secret-at-least-thirty-two-bytes",
        email_verification_secret="test-email-secret", password_reset_secret="test-reset-secret",
        avatar_storage_root=str(tmp_path / "bytes"),
        media_url_signing_secret="test-media-url-signing-secret-32b")
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    tokens = TokenService(factory, jwt_secret=settings.jwt_secret, jwt_issuer=settings.jwt_issuer)
    headers = {"Authorization": "Bearer " + tokens.issue_pair(
        user_id="user-a", device_key="device-a", display_name="test").access_token}
    media = MediaRepository(factory, backend=backend).ingest(IngestRequest(
        owner_id="user-a", origin_domain="moments", kind=MediaKind.IMAGE,
        mime="image/png", content=b"private-media-content", digest_kind=DigestKind.PLAINTEXT,
        visibility=VisibilityTier.PRIVATE))
    profiles = ProfileService(factory, storage=storage)
    png = (Path(__file__).parents[1] / "identity/fixtures/avatar.png").read_bytes()
    upload = profiles.begin_avatar_upload("user-a", mime_type="image/png", byte_size=len(png),
        idempotency_key="avatar-seed")
    profiles.put_avatar_content("user-a", upload.id, content_type="image/png", content=png)
    avatar = profiles.complete_avatar_upload("user-a", upload.id,
        idempotency_key="avatar-complete", trace_id="test", source_ip=None)
    pending = profiles.begin_avatar_upload("user-a", mime_type="image/png", byte_size=len(png),
        idempotency_key="avatar-pending")
    profiles.put_avatar_content("user-a", pending.id, content_type="image/png", content=png)
    sessions.clear()
    transport.bodies.clear()
    yield app, headers, media.media_id, avatar.avatar_url, pending.id, png, transport, sessions
    assert all(session.was_closed for session in sessions)
    assert all(body.closed for body in transport.bodies)
    engine.dispose()


async def media_request(client, env, route):
    _, headers, media_id, avatar_url, pending_id, png, transport, _ = env
    if route == "signed":
        minted = await client.post(f"/api/v1/media/platform/objects/{media_id}/signed-urls",
            headers=headers, json={"variant_kind": "original", "tier": "private"})
        assert minted.status_code == 200
        return "GET", minted.json()["url"], {"headers": headers}
    if route == "variant":
        return "GET", f"/api/v1/media/platform/objects/{media_id}/variants/original", {"headers": headers}
    if route == "avatar":
        return "GET", avatar_url, {}
    if route == "avatar_complete":
        return "POST", f"/api/v1/profile/avatar/uploads/{pending_id}/complete", {
            "headers": {**headers, "Idempotency-Key": "complete-request"}}
    if route in {"avatar_cancel", "avatar_delete"}:
        transport.operation = "delete"
        path = f"/api/v1/profile/avatar/uploads/{pending_id}" if route == "avatar_cancel" else "/api/v1/profile/avatar"
        return "DELETE", path, {"headers": {**headers, "Idempotency-Key": "delete-request"}}
    transport.operation = "put"
    if route == "avatar_put":
        return "PUT", f"/api/v1/profile/avatar/uploads/{pending_id}/content", {
            "headers": {**headers, "Content-Type": "image/png"}, "content": png}
    if route == "moment_attach":
        return "POST", "/api/v1/media/platform/moments/attachments?mime=image/png", {
            "headers": {**headers, "Content-Type": "image/png", "Idempotency-Key": "moment-attach"},
            "content": png}
    assert route == "ingest"
    return "POST", "/api/v1/media/platform/objects?kind=image&mime=image/png", {
        "headers": {**headers, "Content-Type": "image/png"}, "content": png}


@pytest.mark.asyncio
@pytest.mark.parametrize("route", ["signed", "variant", "avatar", "ingest", "moment_attach",
    "avatar_put", "avatar_complete", "avatar_cancel", "avatar_delete"])
async def test_slow_storage_leaves_shared_loop_and_light_request_responsive(media_io_env, route):
    app, *_, transport, sessions = media_io_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        method, url, kwargs = await media_request(client, media_io_env, route)
        sessions.clear()
        gate = transport.gate = StorageGate()
        media_task = asyncio.create_task(client.request(method, url, **kwargs))
        try:
            assert await asyncio.to_thread(gate.entered.wait, 2.0)
            # These run on the SAME loop as the real media ASGI request. On the
            # broken route the watchdog has already released storage by now.
            await asyncio.sleep(0.01)
            light = await client.get("/api/v1/health/live")
            assert light.status_code == 200
            assert not gate.finished.is_set(), "synchronous media I/O blocked the shared ASGI event loop"
            assert not media_task.done(), "no response may escape before storage and integrity checks finish"
        finally:
            gate.release.set()
            response = await media_task
        assert response.status_code in {200, 201, 204}, response.text
        assert sessions and all(session.was_closed for session in sessions)
        assert all(session.owner_thread != threading.get_ident() for session in sessions)


@pytest.mark.asyncio
async def test_concurrent_media_work_respects_the_framework_pool_bound(media_io_env):
    app, _, _, avatar_url, *_, transport, _ = media_io_env
    limiter = anyio.to_thread.current_default_thread_limiter()
    previous = limiter.total_tokens
    limiter.total_tokens = 2
    gate = transport.gate = StorageGate()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        tasks = [asyncio.create_task(client.get(avatar_url)) for _ in range(3)]
        try:
            async def two_reads_started():
                while len(transport.bodies) < 2:
                    await asyncio.sleep(0)

            await asyncio.wait_for(two_reads_started(), timeout=0.8)
            await asyncio.sleep(0.01)
            assert len(transport.bodies) == 2, "third read must wait for a worker slot"
            assert limiter.borrowed_tokens == 2
            assert not gate.finished.is_set()
            assert (await client.get("/api/v1/health/live")).status_code == 200
        finally:
            gate.release.set()
            responses = await asyncio.gather(*tasks)
            limiter.total_tokens = previous
        assert all(response.status_code == 200 for response in responses)
        assert len(transport.bodies) == 3


@pytest.mark.asyncio
async def test_cancelled_scope_keeps_worker_owned_until_body_closes(media_io_env):
    app, _, _, avatar_url, *_, transport, sessions = media_io_env
    gate = transport.gate = StorageGate()
    finished = anyio.Event()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        async def read(*, task_status=anyio.TASK_STATUS_IGNORED):
            with anyio.CancelScope() as scope:
                task_status.started(scope)
                await client.get(avatar_url)
            finished.set()

        async with anyio.create_task_group() as group:
            scope = await group.start(read)
            try:
                assert await asyncio.to_thread(gate.entered.wait, 2.0)
                scope.cancel()
                await asyncio.sleep(0.01)
                assert not finished.is_set()
                assert not transport.bodies[0].closed
                assert (await client.get("/api/v1/health/live")).status_code == 200
            finally:
                gate.release.set()
        assert finished.is_set()
        assert all(body.closed for body in transport.bodies)
        assert all(session.was_closed for session in sessions)


@pytest.mark.asyncio
@pytest.mark.parametrize("failure", ["timeout", "checksum", "no_space"])
async def test_storage_failure_never_returns_unverified_bytes_and_releases_resources(media_io_env, failure):
    app, *_, transport, sessions = media_io_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        route = "ingest" if failure == "no_space" else "signed"
        method, url, kwargs = await media_request(client, media_io_env, route)
        sessions.clear()
        if failure == "checksum":
            transport.bad_checksum = True
        else:
            transport.failure = TimeoutError() if failure == "timeout" else OSError(errno.ENOSPC, "disk full")
        response = await client.request(method, url, **kwargs)
        assert response.status_code == 503
        assert response.json()["error"]["code"] == "MEDIA_STORAGE_UNAVAILABLE"
        assert b"private-media-content" not in response.content
        assert all(body.closed for body in transport.bodies)
        assert sessions and all(session.was_closed for session in sessions)
        assert all(session.owner_thread != threading.get_ident() for session in sessions)
        transport.failure = None
        transport.bad_checksum = False
        recovered = await client.request(method, url, **kwargs)
        assert recovered.status_code in {200, 201}


@pytest.mark.asyncio
async def test_queued_avatar_read_rechecks_revocation_when_worker_starts(media_io_env):
    app, _, _, avatar_url, *_, transport, _ = media_io_env
    limiter = anyio.to_thread.current_default_thread_limiter()
    previous = limiter.total_tokens
    limiter.total_tokens = 1
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        method, url, kwargs = await media_request(client, media_io_env, "signed")
        gate = transport.gate = StorageGate()
        running = asyncio.create_task(client.request(method, url, **kwargs))
        queued = None
        try:
            assert await asyncio.to_thread(gate.entered.wait, 2.0)
            queued = asyncio.create_task(client.get(avatar_url))

            def revoke():
                with app.state.session_factory.begin() as session:
                    session.get(User, "user-a").avatar_object_key = None

            await asyncio.to_thread(revoke)
            assert not gate.finished.is_set()
        finally:
            gate.release.set()
            initial = await running
            revoked = await queued if queued is not None else None
            limiter.total_tokens = previous
        assert initial.status_code == 200
        assert revoked.status_code == 404
        assert revoked.json()["error"]["code"] == "AVATAR_URL_INVALID"
        assert len(transport.bodies) == 1, "revoked queued read must not reach storage"
