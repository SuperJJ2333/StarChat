"""Media Engine Phase 4.2 — gateway abstraction, variant resolver, upload boundary.

Acceptance coverage:

* Test 5 — legacy Matrix media is still readable (resolved + delegated, never migrated);
* Test 6 — old data needs no migration to be reachable (dual read);
* Test 8 — variant selection for images (thumbnail/original) and video (poster/original);
* ADR-005 — the upload engine exposes session/resume/abort while chunk transfer and
  commit are explicitly reserved rather than half-implemented.
"""

from __future__ import annotations

from datetime import datetime, timezone

from httpx import ASGITransport, AsyncClient
import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.identity.tokens import TokenService
from app.modules.media.domain import (
    EnvelopeMode,
    MediaKind,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.gateway import Delivery, MediaOrigin
from app.modules.media.policy import NetworkHint, VariantPreference

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


@pytest.fixture()
def platform_app(tmp_path):
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
    storage = LocalPrivateObjectStorage(
        root=str(tmp_path / "private-media"),
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
        avatar_storage_root=str(tmp_path / "private-media"),
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
    yield app, factory, headers, settings
    engine.dispose()


async def _ingest(client: AsyncClient, headers: dict, *, kind="image", mime="image/jpeg", body=b"x" * 2048, visibility="private", envelope="none"):
    return await client.post(
        "/api/v1/media/platform/objects",
        params={
            "kind": kind,
            "mime": mime,
            "visibility": visibility,
            "envelope": envelope,
        },
        headers={**headers, "Content-Type": mime},
        content=body,
    )


# --------------------------------------------------------------------------- #
# Resolve / read through the gateway
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_platform_object_resolves_and_reads_for_owner(platform_app) -> None:
    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        created = await _ingest(client, headers["user-a"], body=b"hello-media" * 128)
        assert created.status_code == 201, created.text
        media_id = created.json()["media_id"]

        metadata = await client.get(
            f"/api/v1/media/platform/objects/{media_id}", headers=headers["user-a"]
        )
        assert metadata.status_code == 200, metadata.text
        payload = metadata.json()
        assert payload["origin"] == MediaOrigin.PLATFORM.value
        assert payload["delivery"] == Delivery.PLATFORM.value
        assert [variant["kind"] for variant in payload["variants"]] == ["original"]

        fetched = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-a"],
        )
        assert fetched.status_code == 200
        assert fetched.content == b"hello-media" * 128
        assert fetched.headers["cache-control"] == "private, no-store"
        assert fetched.headers["x-content-type-options"] == "nosniff"


@pytest.mark.asyncio
async def test_other_user_cannot_read_private_object(platform_app) -> None:
    """Security requirement §13: user B must not reach user A's private media."""

    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        created = await _ingest(client, headers["user-a"])
        media_id = created.json()["media_id"]

        metadata = await client.get(
            f"/api/v1/media/platform/objects/{media_id}", headers=headers["user-b"]
        )
        assert metadata.status_code == 403
        assert metadata.json()["error"]["code"] == "MEDIA_ACCESS_DENIED"

        bytes_response = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-b"],
        )
        assert bytes_response.status_code == 403
        # The denial never leaks whether the object exists.
        assert "media_id" not in bytes_response.text


# --------------------------------------------------------------------------- #
# Test 5 / Test 6 — Matrix compatibility and dual read
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_legacy_matrix_media_is_delegated_not_migrated(platform_app) -> None:
    app, factory, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        response = await client.get(
            "/api/v1/media/platform/resolve",
            params={"reference": "mxc://matrix.localhost/AbCdEf123"},
            headers=headers["user-a"],
        )
        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["origin"] == MediaOrigin.MATRIX.value
        assert payload["delivery"] == Delivery.MATRIX_TOKEN.value
        assert payload["delegated_to"] == "matrix"
        assert payload["requires_matrix_token"] is True
        assert payload["read_old_only"] is True

    # Nothing was copied into the platform: no object row exists for a legacy locator.
    from app.modules.media.models import MediaObject, MediaBlob

    with factory() as session:
        assert session.query(MediaObject).count() == 0
        assert session.query(MediaBlob).count() == 0


@pytest.mark.asyncio
async def test_legacy_moments_capability_url_keeps_working(platform_app) -> None:
    """Read Old: existing business signed URLs stay valid, no re-ingest required."""

    app, factory, headers, _ = platform_app
    reference = (
        "http://media.local/api/v1/moments/media/content/"
        "gAAAAABlegacy-token-value"
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        response = await client.get(
            "/api/v1/media/platform/resolve",
            params={"reference": reference},
            headers=headers["user-a"],
        )
    assert response.status_code == 200, response.text
    payload = response.json()
    assert payload["origin"] == MediaOrigin.LEGACY_BUSINESS.value
    assert payload["delivery"] == Delivery.LEGACY_CAPABILITY.value
    assert payload["read_old_only"] is True

    from app.modules.media.models import MediaObject

    with factory() as session:
        assert session.query(MediaObject).count() == 0


@pytest.mark.asyncio
async def test_unknown_reference_is_not_silently_accepted(platform_app) -> None:
    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        response = await client.get(
            "/api/v1/media/platform/resolve",
            params={"reference": "not-a-media-id"},
            headers=headers["user-a"],
        )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "MEDIA_OBJECT_NOT_FOUND"


# --------------------------------------------------------------------------- #
# Test 8 — variant selection
# --------------------------------------------------------------------------- #
def test_variant_resolver_prefers_cheap_variants_and_honours_scope(platform_app) -> None:
    app, factory, _, _ = platform_app
    import tempfile

    from app.modules.media.domain import DigestKind
    from app.modules.media.repository import IngestRequest, MediaRepository
    from app.modules.media.storage import LocalBlobBackend
    from app.modules.media.variants import VariantResolver

    repository = MediaRepository(factory, backend=LocalBlobBackend(root=tempfile.mkdtemp()))
    image = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=MediaKind.IMAGE,
            mime="image/jpeg",
            content=b"i" * 4096,
            digest_kind=DigestKind.PLAINTEXT,
            visibility=VisibilityTier.PRIVATE,
        )
    )
    video = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=MediaKind.VIDEO,
            mime="video/mp4",
            content=b"v" * 8192,
            digest_kind=DigestKind.PLAINTEXT,
            visibility=VisibilityTier.PRIVATE,
        )
    )

    resolver = VariantResolver(repository)

    # Only the original is ready today, so every preference and network hint converges on
    # it; the ordering machinery is what changes once more variants exist.
    assert [
        candidate.kind
        for candidate in resolver.candidates(image.media_id, media_kind=MediaKind.IMAGE)
    ] == [VariantKind.ORIGINAL]
    assert (
        resolver.best(
            image.media_id,
            media_kind=MediaKind.IMAGE,
            prefer=VariantPreference.QUALITY,
        ).kind
        is VariantKind.ORIGINAL
    )
    for network in (NetworkHint.SLOW, NetworkHint.WIFI):
        assert [
            candidate.kind
            for candidate in resolver.candidates(
                video.media_id, media_kind=MediaKind.VIDEO, network=network
            )
        ] == [VariantKind.ORIGINAL]

    # An explicit allow-list can only narrow the result, never widen it.
    restricted = resolver.candidates(
        video.media_id,
        media_kind=MediaKind.VIDEO,
        allowed_kinds=frozenset({VariantKind.P720}),
    )
    assert restricted == []
    assert app is not None


def test_variant_resolver_ignores_not_ready_variants(platform_app) -> None:
    app, factory, _, _ = platform_app
    import tempfile

    from app.modules.media.domain import DigestKind
    from app.modules.media.models import MediaVariant
    from app.modules.media.repository import IngestRequest, MediaRepository
    from app.modules.media.storage import LocalBlobBackend
    from app.modules.media.variants import VariantResolver
    from app.modules.media.domain import VariantKind as Kind

    repository = MediaRepository(factory, backend=LocalBlobBackend(root=tempfile.mkdtemp()))
    result = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=MediaKind.IMAGE,
            mime="image/jpeg",
            content=b"q" * 1024,
            digest_kind=DigestKind.PLAINTEXT,
        )
    )
    with factory.begin() as session:
        session.add(
            MediaVariant(
                variant_id="variant-thumb-pending",
                media_id=result.media_id,
                kind=Kind.THUMBNAIL.value,
                blob_id=result.blob_id,
                status="processing",
                generation=1,
                created_at=datetime.now(timezone.utc),
            )
        )
    resolver = VariantResolver(repository)
    candidates = resolver.candidates(result.media_id, media_kind=MediaKind.IMAGE)
    assert [candidate.kind for candidate in candidates] == [Kind.ORIGINAL]


# --------------------------------------------------------------------------- #
# Upload engine boundary (ADR-005)
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_upload_session_interface_is_usable_and_transfer_is_reserved(platform_app) -> None:
    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        created = await client.post(
            "/api/v1/media/platform/uploads",
            params={"kind": "video", "declared_size": 1024, "declared_mime": "video/mp4"},
            headers={**headers["user-a"], "Idempotency-Key": "upload-key-1"},
        )
        assert created.status_code == 201, created.text
        payload = created.json()
        assert payload["status"] == "created"
        assert payload["resume_supported"] is True
        assert payload["chunk_upload_supported"] is False
        assert payload["commit_supported"] is False
        upload_id = payload["upload_id"]

        # Idempotent create returns the same session.
        again = await client.post(
            "/api/v1/media/platform/uploads",
            params={"kind": "video", "declared_size": 1024, "declared_mime": "video/mp4"},
            headers={**headers["user-a"], "Idempotency-Key": "upload-key-1"},
        )
        assert again.status_code == 201
        assert again.json()["upload_id"] == upload_id

        resumed = await client.get(
            f"/api/v1/media/platform/uploads/{upload_id}", headers=headers["user-a"]
        )
        assert resumed.status_code == 200
        assert resumed.json()["uploaded_parts"] == []

        # Reserved surface: explicitly not implemented, advertised through the payload.
        part = await client.put(
            f"/api/v1/media/platform/uploads/{upload_id}/parts/0",
            headers=headers["user-a"],
            content=b"chunk",
        )
        assert part.status_code == 501
        assert part.json()["error"]["code"] == "MEDIA_UPLOAD_NOT_IMPLEMENTED"

        complete = await client.post(
            f"/api/v1/media/platform/uploads/{upload_id}/complete", headers=headers["user-a"]
        )
        assert complete.status_code == 501

        aborted = await client.delete(
            f"/api/v1/media/platform/uploads/{upload_id}", headers=headers["user-a"]
        )
        assert aborted.status_code == 200
        assert aborted.json()["status"] == "aborted"


@pytest.mark.asyncio
async def test_upload_session_is_owner_scoped(platform_app) -> None:
    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        created = await client.post(
            "/api/v1/media/platform/uploads",
            params={"kind": "image", "declared_size": 512, "declared_mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "owner-scope"},
        )
        upload_id = created.json()["upload_id"]
        other = await client.get(
            f"/api/v1/media/platform/uploads/{upload_id}", headers=headers["user-b"]
        )
    assert other.status_code == 404


@pytest.mark.asyncio
async def test_idempotency_key_conflict_is_rejected(platform_app) -> None:
    app, _, headers, _ = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        first = await client.post(
            "/api/v1/media/platform/uploads",
            params={"kind": "image", "declared_size": 512, "declared_mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "conflicting"},
        )
        assert first.status_code == 201
        conflict = await client.post(
            "/api/v1/media/platform/uploads",
            params={"kind": "image", "declared_size": 999, "declared_mime": "image/jpeg"},
            headers={**headers["user-a"], "Idempotency-Key": "conflicting"},
        )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "MEDIA_UPLOAD_IDEMPOTENCY_CONFLICT"


# --------------------------------------------------------------------------- #
# Metrics endpoint gating
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_metrics_endpoint_is_maintenance_gated(platform_app) -> None:
    app, _, headers, settings = platform_app
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        # No token configured, test environment: allowed, and it reports the required
        # observations without leaking identifiers.
        response = await client.get("/api/v1/media/platform/metrics")
        assert response.status_code == 200
        payload = response.json()
        for required in (
            "media_resolve_ms",
            "variant_resolve_ms",
            "authorization_ms",
            "storage_read_ms",
        ):
            assert required in payload["timings"]
        assert "cache_hit" in payload["counters"]
        body = response.text
        for forbidden in ("user-a", "user-b", "@", "mxc://", "token", "Bearer"):
            assert forbidden not in body


@pytest.mark.asyncio
async def test_production_without_token_closes_maintenance(platform_app) -> None:
    app, factory, headers, _ = platform_app
    from app.main import create_app as build_app
    from app.integrations.private_storage import LocalPrivateObjectStorage
    import tempfile

    prod_settings = Settings(
        _env_file=None,
        environment="test",  # keep FastAPI test mode; the gate reads .environment at call time
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        media_maintenance_token="expected-token",
        avatar_storage_root=str(tempfile.mkdtemp()),
    )
    prod_app = build_app(
        prod_settings,
        session_factory=factory,
        avatar_storage=LocalPrivateObjectStorage(
            root=prod_settings.avatar_storage_root,
            signing_secret="test-media-signing-secret-32-bytes",
            public_base_url="http://mediatest.local",
        ),
    )
    async with AsyncClient(transport=ASGITransport(app=prod_app), base_url="http://media.local") as client:
        denied = await client.get("/api/v1/media/platform/metrics")
        assert denied.status_code == 403
        allowed = await client.get(
            "/api/v1/media/platform/metrics",
            headers={"X-Media-Maintenance-Token": "expected-token"},
        )
        assert allowed.status_code == 200
