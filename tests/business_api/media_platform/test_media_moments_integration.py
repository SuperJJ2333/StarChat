"""Media Engine Phase 4.7 — Moments integration through the gateway.

The point of these tests is that nothing in the existing Moments module changed:

* a new upload (`Moments → MediaGateway → MediaObject`) can be published with the
  **unchanged** `POST /api/v1/moments` endpoint and then read back through the **unchanged**
  `GET /api/v1/moments/media/content/{token}` reader;
* old media remains readable without migration (Test 6): a capability minted the legacy way
  still resolves and still serves its bytes;
* the platform reference exists, so the collector can count it (Test 7 interaction);
* releasing a moment's reference never touches another business object's media.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from io import BytesIO

from httpx import ASGITransport, AsyncClient
from PIL import Image
import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService
from app.modules.media.domain import (
    BusinessType,
    GcMode,
    MediaStatus,
    VisibilityTier,
)
from app.modules.media.lifecycle import MediaGarbageCollector
from app.modules.media.models import MediaBlob, MediaObject
from app.modules.media.policy import MediaPlatformPolicy
from app.modules.media.storage import LocalBlobBackend
from app.modules.moments.media import MomentMediaUpload

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


def _jpeg(width: int = 640, height: int = 480) -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (width, height), (40, 120, 200)).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture()
def moments_env(tmp_path):
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for user_id, username in (("user-a", "usera"), ("user-b", "userb")):
            session.add(
                User(
                    id=user_id,
                    username=username,
                    username_normalized=username,
                    email=f"{username}@example.com",
                    email_normalized=f"{username}@example.com",
                    password_hash="hash",
                    status=AccountStatus.ACTIVE,
                    email_verified_at=now,
                    created_at=now,
                    updated_at=now,
                )
            )
    root = str(tmp_path / "private-media")
    storage = LocalPrivateObjectStorage(
        root=root,
        signing_secret="test-media-signing-secret-32-bytes",
        public_base_url="http://mediatest.local",
    )
    settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        avatar_storage_root=root,
        media_url_signing_secret="test-media-url-signing-secret-32b",
    )
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    tokens = TokenService(factory, jwt_secret=JWT_SECRET, jwt_issuer="liuhetong")
    headers = {
        user_id: {
            "Authorization": "Bearer "
            + tokens.issue_pair(
                user_id=user_id, device_key=f"device-{user_id}", display_name=user_id
            ).access_token
        }
        for user_id in ("user-a", "user-b")
    }
    yield app, factory, storage, headers, root
    engine.dispose()


@pytest.mark.asyncio
async def test_new_upload_path_feeds_the_unchanged_moments_reader(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    payload = _jpeg()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        attached = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"file_name": "photo.jpg", "mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-1"},
            content=payload,
        )
        assert attached.status_code == 201, attached.text
        attachment = attached.json()
        assert attachment["media_id"]
        assert attachment["capability_url"].startswith("http://mediatest.local/api/v1/moments/media/content/")

        # The unchanged Moments publish endpoint accepts the capability URL produced by the
        # new upload path, because the bridge registered a compatible upload row.
        published = await client.post(
            "/api/v1/moments",
            json={
                "text": "bridge photo",
                "visibility": "PUBLIC",
                "image_urls": [attachment["capability_url"]],
            },
            headers={**headers["user-a"], "Idempotency-Key": "moment-bridge-1"},
        )
        assert published.status_code == 201, published.text
        moment_id = published.json()["id"]

        feed = await client.get(
            "/api/v1/moments/feed", params={"mode": "latest"}, headers=headers["user-a"]
        )
        assert feed.status_code == 200
        items = [item for item in feed.json()["items"] if item["id"] == moment_id]
        assert items, feed.text
        image_urls = items[0]["image_urls"]
        assert image_urls, items[0]

        # The unchanged reader serves the platform's bytes straight from the shared store.
        fetched = await client.get(image_urls[0])
        assert fetched.status_code == 200
        assert fetched.content == payload


@pytest.mark.asyncio
async def test_bridge_creates_platform_object_and_reference(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        attached = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-object"},
            content=_jpeg(),
        )
    assert attached.status_code == 201, attached.text
    media_id = attached.json()["media_id"]

    with factory() as session:
        media = session.get(MediaObject, media_id)
        blob = session.scalars(select(MediaBlob)).first()
        upload = session.scalars(
            select(MomentMediaUpload).where(MomentMediaUpload.id == attached.json()["upload_id"])
        ).first()

    assert media is not None
    assert media.owner_scope == "user:user-a"  # per-owner plaintext isolation
    assert media.visibility_hint == VisibilityTier.AUDIENCE.value
    assert media.ref_count == 1  # the platform reference is counted
    assert blob is not None and upload is not None
    # The legacy bookkeeping row points at the platform's bytes: one copy, two readers.
    assert upload.object_key == blob.storage_key
    assert blob.storage_key.startswith("moments/")
    # The isolation address is still inside the key, it is just not the prefix.
    assert "/media/user/" in blob.storage_key
    assert "user-a" not in blob.storage_key
    assert upload.status == "COMPLETED"


@pytest.mark.asyncio
async def test_bridge_is_idempotent_per_key(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    payload = _jpeg()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        first = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-same"},
            content=payload,
        )
        second = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-same"},
            content=payload,
        )
    assert first.status_code == 201 and second.status_code == 201
    assert first.json()["upload_id"] == second.json()["upload_id"]
    assert first.json()["media_id"] == second.json()["media_id"]
    with factory() as session:
        assert len(list(session.scalars(select(MomentMediaUpload)))) == 1


@pytest.mark.asyncio
async def test_bridge_validates_like_the_legacy_path(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        wrong_type = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "application/pdf"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-bad-1"},
            content=b"%PDF-1.4",
        )
        assert wrong_type.status_code == 422
        assert wrong_type.json()["error"]["code"] == "MOMENT_MEDIA_INVALID"

        too_big = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "bridge-bad-2"},
            content=b"\xff\xd8" + b"0" * (21 * 1024 * 1024),
        )
        assert too_big.status_code == 422


@pytest.mark.asyncio
async def test_legacy_media_still_readable_without_migration(moments_env) -> None:
    """Test 6: an old-style upload keeps working, and the platform has no object for it."""

    app, factory, storage, headers, _ = moments_env
    payload = _jpeg(320, 240)
    object_key = "moments/user-a/legacy-upload.jpg"
    storage.put(object_key, payload)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(
            MomentMediaUpload(
                id="legacy-upload",
                owner_id="user-a",
                file_name="legacy.jpg",
                mime_type="image/jpeg",
                byte_size=len(payload),
                status="COMPLETED",
                object_key=object_key,
                purpose="MOMENT_IMAGE",
                idempotency_key="legacy-key",
                created_at=now - timedelta(days=30),
                expires_at=now + timedelta(days=1),
            )
        )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        capability = storage.moment_read_url(
            '{"domain":"moment-upload-v1","key":"%s","upload":"legacy-upload","viewer":"user-a"}'
            % object_key
        )
        fetched = await client.get(capability)
        assert fetched.status_code == 200
        assert fetched.content == payload

    # No platform row was created for the legacy object: nothing was migrated.
    with factory() as session:
        assert session.query(MediaObject).count() == 0


@pytest.mark.asyncio
async def test_releasing_a_moment_reference_leaves_other_media_alone(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        first = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "release-1"},
            content=_jpeg(200, 200),
        )
        second = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "release-2"},
            content=_jpeg(201, 201),
        )
        kept_media = second.json()["media_id"]

        released = await client.post(
            "/api/v1/media/platform/releases",
            json={"business_type": "moment_upload", "business_id": first.json()["upload_id"]},
            params={"reason": "moment_deleted"},
            headers=headers["user-a"],
        )
        assert released.status_code == 200, released.text
        assert len(released.json()["released"]) == 1

        # The other attachment is untouched and still readable through the platform.
        still_there = await client.get(
            f"/api/v1/media/platform/objects/{kept_media}/variants/original",
            headers=headers["user-a"],
        )
        assert still_there.status_code == 200

        # And a non-owner cannot release somebody else's reference.
        forbidden = await client.post(
            "/api/v1/media/platform/releases",
            json={"business_type": "moment_upload", "business_id": second.json()["upload_id"]},
            headers=headers["user-b"],
        )
        assert forbidden.status_code == 200
        assert forbidden.json()["released"] == []


@pytest.mark.asyncio
async def test_released_moment_media_is_collected_after_grace(moments_env) -> None:
    app, factory, storage, headers, root = moments_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        attached = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "collect-1"},
            content=_jpeg(300, 300),
        )
        media_id = attached.json()["media_id"]
        released = await client.post(
            "/api/v1/media/platform/releases",
            json={"business_type": "moment_upload", "business_id": attached.json()["upload_id"]},
            headers=headers["user-a"],
        )
        assert released.status_code == 200

    with factory() as session:
        assert session.get(MediaObject, media_id).status == MediaStatus.ORPHAN.value

    collector = MediaGarbageCollector(
        factory,
        backend=LocalBlobBackend(root=root),
        policy=MediaPlatformPolicy(orphan_grace_seconds=0),
    )
    report = collector.run(mode=GcMode.ENFORCE)
    assert report.collected == 1
    with factory() as session:
        assert session.get(MediaObject, media_id).status == MediaStatus.DELETED.value
        blob = session.scalars(select(MediaBlob)).first()
        assert blob.status == "DELETED"


@pytest.mark.asyncio
async def test_bridge_requires_authentication_and_an_idempotency_key(moments_env) -> None:
    app, factory, storage, headers, _ = moments_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        unauthenticated = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers={"Idempotency-Key": "no-auth"},
            content=_jpeg(),
        )
        assert unauthenticated.status_code == 401

        no_key = await client.post(
            "/api/v1/media/platform/moments/attachments",
            params={"mime": "image/jpeg"},
            headers=headers["user-a"],
            content=_jpeg(),
        )
        assert no_key.status_code == 422
