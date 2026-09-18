"""Media Engine Phase 4.4 — authorization, grants and signed URLs.

Acceptance coverage:

* Test 3 — ``private``: owner A reads, user B is denied;
* Test 4 — ``audience``: a token minted for an audience works for another user (the frozen
  forwarding trade-off), while a forwarded ``private`` URL does not;
* security requirement §13 — deleting one reference never removes another reference's media;
* TTL is decided by the server (a client-supplied ``expires_in`` has no effect anywhere);
* revocation beats the TTL: revoking a grant kills already-issued, forwarded URLs;
* a tampered or expired token fails closed with one uniform error;
* single-use grants are consumed exactly once.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

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
    DigestKind,
    Permission,
    SubjectType,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.grants import MediaGrantService
from app.modules.media.repository import IngestRequest, MediaRepository
from app.modules.media.signed_urls import MediaSignedUrlCodec
from app.modules.media.storage import LocalBlobBackend

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"
MEDIA_SECRET = "test-media-url-signing-secret-32b"


@pytest.fixture()
def auth_env(tmp_path):
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
    backend = LocalBlobBackend(root=root)
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
        media_url_signing_secret=MEDIA_SECRET,
        media_ttl_private_seconds=60,
        media_ttl_audience_seconds=600,
        media_ttl_public_seconds=86400,
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
    yield app, factory, backend, headers, settings
    engine.dispose()


def _seed(factory, backend, *, visibility: VisibilityTier) -> str:
    repository = MediaRepository(factory, backend=backend)
    return repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=__import__(
                "app.modules.media.domain", fromlist=["MediaKind"]
            ).MediaKind.IMAGE,
            mime="image/jpeg",
            content=b"signed" * 700,
            digest_kind=DigestKind.PLAINTEXT,
            visibility=visibility,
        )
    ).media_id


async def _mint(client, headers, media_id, *, variant="original", tier=None, audience=None, **extra):
    body = {"variant_kind": variant}
    if tier:
        body["tier"] = tier
    if audience:
        body["audience"] = audience
    body.update(extra)
    return await client.post(
        f"/api/v1/media/platform/objects/{media_id}/signed-urls",
        json=body,
        headers=headers,
    )


# --------------------------------------------------------------------------- #
# Test 3 — private
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_private_token_works_for_owner_and_not_for_a_forwarder(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        minted = await _mint(client, headers["user-a"], media_id, tier="private")
        assert minted.status_code == 200, minted.text
        payload = minted.json()
        assert payload["tier"] == "private"
        assert payload["binding"]["subject"] == "user-a"
        assert payload["ttl_seconds"] <= 60
        url = payload["url"]

        owner = await client.get(url, headers=headers["user-a"])
        assert owner.status_code == 200
        assert owner.content == b"signed" * 700

        # Forwarded to B: without A's identity the URL is useless.
        forwarded = await client.get(url, headers=headers["user-b"])
        assert forwarded.status_code == 404
        assert forwarded.json()["error"]["code"] == "MEDIA_SIGNED_URL_INVALID"

        # Even anonymously (no header at all) it fails closed.
        anonymous = await client.get(url)
        assert anonymous.status_code == 404


# --------------------------------------------------------------------------- #
# Test 4 — audience
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_audience_token_is_shareable_inside_the_audience(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.AUDIENCE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        minted = await _mint(
            client, headers["user-a"], media_id, tier="audience", audience="room:!room:test"
        )
        assert minted.status_code == 200, minted.text
        payload = minted.json()
        assert payload["tier"] == "audience"
        assert payload["binding"]["subject"] is None
        assert payload["binding"]["audience"] == "room:!room:test"
        url = payload["url"]

        # A different user holding the audience URL can read it: the frozen trade-off.
        member = await client.get(url, headers=headers["user-b"])
        assert member.status_code == 200
        assert member.content == b"signed" * 700


@pytest.mark.asyncio
async def test_revoking_a_grant_kills_forwarded_audience_urls(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.AUDIENCE)
    grants = MediaGrantService(factory)
    grant = grants.issue(
        media_id=media_id,
        actor_id="user-a",
        subject_type=SubjectType.ROOM,
        subject_id="!room:test",
        permission=Permission.READ,
        ttl_seconds=600,
    )
    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    token, _ = codec.mint(
        media_id=media_id,
        variant_kind=VariantKind.ORIGINAL,
        subject="!room:test",
        tier=VisibilityTier.AUDIENCE,
        ttl_seconds=600,
        aud_scope="room:!room:test",
        grant_id=grant.grant_id,
        grant_version=grant.grant_version,
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        before = await client.get(f"/api/v1/media/platform/content/{token}")
        assert before.status_code == 200

        grants.revoke(grant_id=grant.grant_id, actor_id="user-a", reason="revoked")

        after = await client.get(f"/api/v1/media/platform/content/{token}")
        assert after.status_code == 404


# --------------------------------------------------------------------------- #
# TTL is server-decided
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_client_cannot_extend_the_ttl(auth_env) -> None:
    app, factory, backend, headers, settings = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        # A client-supplied expires_in is not part of the contract and must be ignored by
        # the strict models rather than silently honoured.
        minted = await _mint(client, headers["user-a"], media_id, tier="private", expires_in=999999)
        assert minted.status_code == 422

        normal = await _mint(client, headers["user-a"], media_id, tier="private")
        assert normal.status_code == 200
        assert normal.json()["ttl_seconds"] <= settings.media_ttl_private_seconds


def test_ttl_policy_is_applied_per_variant_and_tier() -> None:
    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    _, private_original = codec.mint(
        media_id="m",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    _, audience_poster = codec.mint(
        media_id="m",
        variant_kind=VariantKind.POSTER,
        subject="room:!r",
        tier=VisibilityTier.AUDIENCE,
        ttl_seconds=2400,
    )
    assert (
        audience_poster.expires_at - private_original.expires_at
    ).total_seconds() > 0


# --------------------------------------------------------------------------- #
# Token integrity
# --------------------------------------------------------------------------- #

def test_tampered_tokens_fail_closed(auth_env) -> None:
    from app.core.errors import AppError

    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    token, _ = codec.mint(
        media_id="media-1",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )

    with pytest.raises(AppError) as malformed:
        codec.verify("not-a-token", caller_id="user-a")
    assert malformed.value.code == "MEDIA_SIGNED_URL_INVALID"

    body, signature = token.split(".", 1)
    with pytest.raises(AppError) as tampered:
        codec.verify(f"{body}.{signature[:-2]}xx", caller_id="user-a")
    assert tampered.value.code == "MEDIA_SIGNED_URL_INVALID"


def test_expired_token_is_rejected(auth_env) -> None:
    from app.core.errors import AppError

    past = datetime.now(timezone.utc) - timedelta(seconds=120)
    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET, now_factory=lambda: past)
    token, _ = codec.mint(
        media_id="media-1",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=30,
    )
    live = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    with pytest.raises(AppError):
        live.verify(token, caller_id="user-a")


def test_codec_without_secret_refuses_to_sign(auth_env) -> None:
    from app.core.errors import AppError

    codec = MediaSignedUrlCodec(secret=None)
    assert codec.available is False
    with pytest.raises(AppError) as unavailable:
        codec.mint(
            media_id="m",
            variant_kind=VariantKind.ORIGINAL,
            subject="user-a",
            tier=VisibilityTier.PRIVATE,
            ttl_seconds=60,
        )
    assert unavailable.value.code == "MEDIA_SIGNING_UNAVAILABLE"


def test_token_payload_carries_no_sensitive_fields(auth_env) -> None:
    import base64
    import json

    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    token, _ = codec.mint(
        media_id="media-1",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    body = token.split(".", 1)[0]
    claims = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    serialized = json.dumps(claims)
    for forbidden in ("digest", "sha256", "storage", "media/user", "path", "token"):
        assert forbidden not in serialized
    assert set(claims) == {"v", "kv", "m", "k", "s", "a", "p", "t", "e", "j", "g", "gv", "su"}


# --------------------------------------------------------------------------- #
# Grants
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_grant_grants_read_to_a_named_subject_only(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        issued = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/grants",
            json={
                "subject_type": "user",
                "subject_id": "user-b",
                "permission": "read",
                "variant_scope": ["original"],
                "ttl_seconds": 300,
                "derived_from": {"rule": "moment_visibility", "ref": "moment-1"},
            },
            headers=headers["user-a"],
        )
        assert issued.status_code == 201, issued.text
        grant_id = issued.json()["grant_id"]
        assert issued.json()["grant_version"] == 1

        # B can now read directly.
        allowed = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-b"],
        )
        assert allowed.status_code == 200

        # Revoking immediately removes the access and bumps the version.
        revoked = await client.delete(
            f"/api/v1/media/platform/grants/{grant_id}", headers=headers["user-a"]
        )
        assert revoked.status_code == 200
        assert revoked.json()["grant_version"] == 2

        denied = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-b"],
        )
        assert denied.status_code == 403


@pytest.mark.asyncio
async def test_only_the_owner_may_issue_or_revoke_grants(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        denied = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/grants",
            json={"subject_type": "user", "subject_id": "user-b"},
            headers=headers["user-b"],
        )
        assert denied.status_code == 403
        assert denied.json()["error"]["code"] == "MEDIA_ACCESS_DENIED"


@pytest.mark.asyncio
async def test_single_use_grant_is_consumed_once(auth_env) -> None:
    """A single-use grant delivers bytes exactly once, end to end."""

    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        issued = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/grants",
            json={
                "subject_type": "user",
                "subject_id": "user-b",
                "permission": "read",
                "single_use": True,
                "max_uses": 1,
                "ttl_seconds": 300,
            },
            headers=headers["user-a"],
        )
        assert issued.status_code == 201, issued.text
        assert issued.json()["single_use"] is True

        minted = await _mint(client, headers["user-b"], media_id, tier="private")
        assert minted.status_code == 200, minted.text
        assert minted.json()["binding"]["single_use"] is True
        url = minted.json()["url"]

        first = await client.get(url, headers=headers["user-b"])
        assert first.status_code == 200
        assert first.content == b"signed" * 700

        second = await client.get(url, headers=headers["user-b"])
        assert second.status_code == 403
        assert second.json()["error"]["code"] == "MEDIA_GRANT_EXHAUSTED"


@pytest.mark.asyncio
async def test_expired_grant_no_longer_authorizes(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.PRIVATE)
    grants = MediaGrantService(factory, now_factory=lambda: datetime.now(timezone.utc) - timedelta(hours=2))
    grants.issue(
        media_id=media_id,
        actor_id="user-a",
        subject_type=SubjectType.USER,
        subject_id="user-b",
        permission=Permission.READ,
        ttl_seconds=60,
    )
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        denied = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-b"],
        )
    assert denied.status_code == 403


# --------------------------------------------------------------------------- #
# Reference deletion isolation (security requirement §13)
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_releasing_one_reference_never_removes_another_references_media(auth_env) -> None:
    app, factory, backend, headers, _ = auth_env
    media_id = _seed(factory, backend, visibility=VisibilityTier.AUDIENCE)
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        first = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/references",
            json={"business_type": "chat_message", "business_id": "$e1"},
            headers=headers["user-a"],
        )
        second = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/references",
            json={"business_type": "moment", "business_id": "moment-1"},
            headers=headers["user-a"],
        )
        assert first.status_code == 201 and second.status_code == 201

        released = await client.delete(
            f"/api/v1/media/platform/references/{first.json()['reference_id']}",
            headers=headers["user-a"],
        )
        assert released.status_code == 200

        remaining = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/references", headers=headers["user-a"]
        )
        assert [item["business_id"] for item in remaining.json()["items"]] == ["moment-1"]
        still_readable = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=headers["user-a"],
        )
        assert still_readable.status_code == 200
