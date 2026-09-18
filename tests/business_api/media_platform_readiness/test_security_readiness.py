"""Part 2 — security audit: Security-001 … Security-005 from the readiness checklist.

The point of these cases is the *boundary*, not the happy path: an unauthenticated caller, a
non-owner, a forwarded URL, a tampered claim, an expired token, a revoked grant, and a
non-member of an audience must all fail — and must fail without leaking whether the object
exists.
"""

from __future__ import annotations

MEDIA_SECRET = "readiness-media-url-signing-secret-32b"

import base64
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from app.modules.friendship.models import Friendship
from app.modules.media.domain import (
    BusinessType,
    Permission,
    SubjectType,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.grants import MediaGrantService
from app.modules.moments.models import Moment



async def _ingest(client, headers, *, visibility="private", body=b"security-payload" * 64):
    return await client.post(
        "/api/v1/media/platform/objects",
        params={"kind": "image", "mime": "image/jpeg", "visibility": visibility},
        headers={**headers, "Content-Type": "image/jpeg"},
        content=body,
    )


async def _mint(client, headers, media_id, **body):
    payload = {"variant_kind": "original"}
    payload.update(body)
    return await client.post(
        f"/api/v1/media/platform/objects/{media_id}/signed-urls",
        json=payload,
        headers=headers,
    )


# --------------------------------------------------------------------------- #
# Security-001 — cross-user read
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_security_001_cross_user_private_read_is_denied(platform) -> None:
    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"])
        assert created.status_code == 201, created.text
        media_id = created.json()["media_id"]

        # B cannot read the bytes, cannot read metadata, and gets no existence signal.
        for path in (
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            f"/api/v1/media/platform/objects/{media_id}",
        ):
            denied = await client.get(path, headers=platform.headers["user-b"])
            assert denied.status_code in (403, 404), (path, denied.status_code)
            assert media_id not in denied.text

        # A cannot mint a URL that B could use either (private binds the subject).
        minted = await _mint(client, platform.headers["user-a"], media_id, tier="private")
        assert minted.status_code == 200
        forwarded = await client.get(minted.json()["url"], headers=platform.headers["user-b"])
        assert forwarded.status_code == 404

        # B cannot even ask for a URL for A's object.
        foreign_mint = await _mint(client, platform.headers["user-b"], media_id, tier="private")
        assert foreign_mint.status_code == 403


# --------------------------------------------------------------------------- #
# Security-002 — URL manipulation / replay
# --------------------------------------------------------------------------- #
def _decode_claims(token: str) -> dict:
    body = token.split(".", 1)[0]
    return json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))


def _reencode(claims: dict, signature: str) -> str:
    body = base64.urlsafe_b64encode(
        json.dumps(claims, separators=(",", ":"), sort_keys=True).encode()
    ).decode().rstrip("=")
    return f"{body}.{signature}"


@pytest.mark.asyncio
async def test_security_002_tampering_with_any_claim_fails(platform) -> None:
    from app.modules.media.signed_urls import MediaSignedUrlCodec

    codec = MediaSignedUrlCodec(secret=MEDIA_SECRET)
    token, _ = codec.mint(
        media_id="media-x",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    original_signature = token.split(".", 1)[1]
    claims = _decode_claims(token)
    assert claims["s"] == "user-a"

    # (a) changing subject / expire without re-signing is rejected (signature covers claims)
    for field, value in (("s", "user-b"), ("e", claims["e"] + 3600), ("m", "media-y"), ("k", "poster")):
        mutated = dict(claims)
        mutated[field] = value
        with pytest.raises(Exception):
            codec.verify(_reencode(mutated, original_signature), caller_id="user-b")

    # (b) even with a *valid* signature, a subject swap does not let another caller in:
    # the private tier re-binds the verified subject to the caller identity.
    forged_token, _ = codec.mint(
        media_id="media-x",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-b",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    assert codec.verify(forged_token, caller_id="user-b").subject == "user-b"
    with pytest.raises(Exception):
        codec.verify(forged_token, caller_id="user-c")

    # (c) the API rejects a token whose signature bytes were edited
    tampered = f"{token[:-4]}AAAA"
    async with platform.client() as client:
        response = await client.get(
            f"/api/v1/media/platform/content/{tampered}", headers=platform.headers["user-a"]
        )
    assert response.status_code == 404


@pytest.mark.asyncio
async def test_security_002b_client_cannot_choose_the_expiry(platform) -> None:
    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"])
        media_id = created.json()["media_id"]

        rejected = await _mint(client, platform.headers["user-a"], media_id, expires_in=999999)
        assert rejected.status_code == 422  # unknown field: the client has no TTL input

        minted = await _mint(client, platform.headers["user-a"], media_id, tier="private")
        payload = minted.json()
        assert payload["ttl_seconds"] <= platform.settings.media_ttl_private_seconds
        claims = _decode_claims(payload["url"].rsplit("/", 1)[-1])
        server_now = int(datetime.now(timezone.utc).timestamp())
        assert claims["e"] <= server_now + platform.settings.media_ttl_private_seconds + 5


# --------------------------------------------------------------------------- #
# Security-003 — expired token
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_security_003_expired_token_is_refused_uniformly(platform) -> None:
    from app.modules.media.signed_urls import MediaSignedUrlCodec

    past = datetime.now(timezone.utc) - timedelta(minutes=10)
    expired_codec = MediaSignedUrlCodec(secret=MEDIA_SECRET, now_factory=lambda: past)
    expired_token, _ = expired_codec.mint(
        media_id="media-expired",
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=30,
    )

    async with platform.client() as client:
        response = await client.get(
            f"/api/v1/media/platform/content/{expired_token}", headers=platform.headers["user-a"]
        )
    assert response.status_code == 404
    body = response.json()
    assert body["error"]["code"] == "MEDIA_SIGNED_URL_INVALID"
    # Uniform failure: no hint about existence, expiry or tampering.
    assert "expired" not in response.text.lower()
    assert "media-expired" not in response.text


# --------------------------------------------------------------------------- #
# Security-004 — grant revocation
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_security_004_revoked_grant_invalidates_existing_urls(platform) -> None:
    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"], visibility="private")
        media_id = created.json()["media_id"]
        grant = MediaGrantService(platform.factory).issue(
            media_id=media_id,
            actor_id="user-a",
            subject_type=SubjectType.USER,
            subject_id="user-b",
            permission=Permission.READ,
            ttl_seconds=600,
        )
        minted = await _mint(client, platform.headers["user-b"], media_id, tier="private")
        assert minted.status_code == 200, minted.text
        url = minted.json()["url"]

        before = await client.get(url, headers=platform.headers["user-b"])
        assert before.status_code == 200

        revoked = await client.delete(
            f"/api/v1/media/platform/grants/{grant.grant_id}", headers=platform.headers["user-a"]
        )
        assert revoked.status_code == 200
        assert revoked.json()["grant_version"] == grant.grant_version + 1

        after = await client.get(url, headers=platform.headers["user-b"])
        assert after.status_code == 404

        direct = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/variants/original",
            headers=platform.headers["user-b"],
        )
        assert direct.status_code == 403


# --------------------------------------------------------------------------- #
# Security-005 — audience boundary
# --------------------------------------------------------------------------- #
def _seed_moment_audience(platform) -> tuple[str, str]:
    """A is the author; B is A's friend (audience member); C is not."""

    now = datetime.now(timezone.utc)
    moment_id = str(uuid4())
    with platform.factory.begin() as session:
        session.add(
            Friendship(
                id=str(uuid4()),
                user_low_id="user-a",
                user_high_id="user-b",
                created_at=now,
            )
        )
        session.add(
            Moment(
                id=moment_id,
                author_id="user-a",
                text="readiness audience",
                visibility="PUBLIC",
                image_urls=[],
                include_user_ids=[],
                exclude_user_ids=[],
                include_tag_ids=[],
                exclude_tag_ids=[],
                location=None,
                link_url=None,
                status="PUBLISHED",
                idempotency_key="readiness-moment",
                created_at=now,
                deleted_at=None,
            )
        )
    return moment_id, f"moment:{moment_id}"


@pytest.mark.asyncio
async def test_security_005_audience_member_can_read_and_outsider_cannot(platform) -> None:
    moment_id, audience_ref = _seed_moment_audience(platform)
    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"], visibility="audience")
        media_id = created.json()["media_id"]
        MediaGrantService(platform.factory).issue(
            media_id=media_id,
            actor_id="user-a",
            subject_type=SubjectType.AUDIENCE,
            subject_id=audience_ref,
            permission=Permission.READ,
            ttl_seconds=600,
            derived_from={"rule": "moment_visibility", "ref": audience_ref},
        )
        minted = await _mint(
            client, platform.headers["user-a"], media_id, tier="audience", audience=audience_ref
        )
        assert minted.status_code == 200, minted.text
        url = minted.json()["url"]

        member = await client.get(url, headers=platform.headers["user-b"])
        assert member.status_code == 200, "an audience member must be able to read"

        outsider = await client.get(url, headers=platform.headers["user-c"])
        assert outsider.status_code == 404, "a non-member must not read an audience URL"

        anonymous = await client.get(url)
        assert anonymous.status_code == 404, "an unverifiable caller must not read"


@pytest.mark.asyncio
async def test_security_005b_audience_is_reverified_after_visibility_changes(platform) -> None:
    """Losing membership must stop access even with a still-valid URL."""

    moment_id, audience_ref = _seed_moment_audience(platform)
    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"], visibility="audience")
        media_id = created.json()["media_id"]
        MediaGrantService(platform.factory).issue(
            media_id=media_id,
            actor_id="user-a",
            subject_type=SubjectType.AUDIENCE,
            subject_id=audience_ref,
            permission=Permission.READ,
            ttl_seconds=600,
            derived_from={"rule": "moment_visibility", "ref": audience_ref},
        )
        minted = await _mint(
            client, platform.headers["user-a"], media_id, tier="audience", audience=audience_ref
        )
        url = minted.json()["url"]
        assert (await client.get(url, headers=platform.headers["user-b"])).status_code == 200

        # A blocks B: the friendship disappears, so B is no longer in the audience.
        from sqlalchemy import delete

        with platform.factory.begin() as session:
            session.execute(delete(Friendship))

        after = await client.get(url, headers=platform.headers["user-b"])
        assert after.status_code == 404


@pytest.mark.asyncio
async def test_security_005c_unverifiable_audience_cannot_be_minted(platform) -> None:
    """A room audience cannot be re-verified by the platform, so it must not be issued."""

    async with platform.client() as client:
        created = await _ingest(client, platform.headers["user-a"], visibility="audience")
        media_id = created.json()["media_id"]
        MediaGrantService(platform.factory).issue(
            media_id=media_id,
            actor_id="user-a",
            subject_type=SubjectType.ROOM,
            subject_id="!room:test",
            permission=Permission.READ,
            ttl_seconds=600,
            derived_from={"rule": "room_membership", "ref": "!room:test"},
        )
        minted = await _mint(
            client, platform.headers["user-a"], media_id, tier="audience", audience="room:!room:test"
        )
    assert minted.status_code in (403, 422), minted.text
