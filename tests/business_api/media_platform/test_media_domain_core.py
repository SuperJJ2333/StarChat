"""Media Engine Phase 4.1 — media domain core.

Covers the frozen ADR-001/ADR-002 rules plus Test 1 of the phase-4 brief
(object/blob/variant relations are correct):

* digest kinds never compare with each other;
* a transport digest can never become an object identity;
* plaintext objects live in a per-owner scope, ciphertext objects in the shared E2EE
  scope, and neither can be written into the other's namespace;
* a plaintext upload by user B never reuses user A's object (no global dedup);
* an E2EE ciphertext upload above the threshold does reuse the object (shipped behaviour)
  while a random envelope never does;
* ingest produces exactly one object + one blob + one ready primary variant.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.pool import StaticPool

from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.modules.media.domain import (
    CrossKindDigestComparison,
    Digest,
    DigestKind,
    EnvelopeMode,
    IsolationDomain,
    IsolationViolation,
    MediaKind,
    MediaStatus,
    VariantKind,
    VariantStatus,
    VisibilityTier,
    allow_cross_user_plaintext_dedup,
    assert_object_domain,
    ciphertext_digest,
    plaintext_digest,
    transport_digest,
)
from app.modules.media.metrics import MediaPlatformMetrics
from app.modules.media.models import MediaBlob, MediaObject, MediaVariant
from app.modules.media.policy import (
    MediaDedupPolicy,
    MediaTtlPolicy,
    NetworkHint,
    VariantPreference,
    variant_preference_order,
)
from app.modules.media.repository import IngestRequest, MediaRepository
from app.modules.media.storage import (
    LocalBlobBackend,
    key_belongs_to_domain,
    storage_key_for,
)


@pytest.fixture()
def media_core(tmp_path):
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    backend = LocalBlobBackend(root=str(tmp_path / "private-media"))
    repository = MediaRepository(factory, backend=backend)
    yield repository, factory, backend
    engine.dispose()


def _ingest(repository, *, owner="user-a", kind=MediaKind.IMAGE, mime="image/jpeg", content=b"a" * 4096, digest_kind=DigestKind.PLAINTEXT, envelope=EnvelopeMode.NONE, visibility=VisibilityTier.PRIVATE):
    return repository.ingest(
        IngestRequest(
            owner_id=owner,
            origin_domain="moments",
            kind=kind,
            mime=mime,
            content=content,
            digest_kind=digest_kind,
            envelope_mode=envelope,
            visibility=visibility,
        )
    )


# --------------------------------------------------------------------------- #
# Test 1 — object / blob / variant relations
# --------------------------------------------------------------------------- #
def test_ingest_creates_object_blob_and_primary_variant(media_core) -> None:
    repository, factory, _ = media_core
    result = _ingest(repository)

    with factory() as session:
        media = session.get(MediaObject, result.media_id)
        blob = session.get(MediaBlob, result.blob_id)
        variants = list(
            session.scalars(select(MediaVariant).where(MediaVariant.media_id == result.media_id))
        )

    assert media is not None and blob is not None
    assert media.status == MediaStatus.ACTIVE.value
    assert media.isolation_domain == IsolationDomain.USER.value
    assert media.owner_scope == "user:user-a"
    assert media.content_digest == plaintext_digest(b"a" * 4096).value
    assert media.digest_kind == DigestKind.PLAINTEXT.value
    assert media.canonical_size == 4096
    # An unreferenced brand new object is protected by the grace period, not by ref_count.
    assert media.ref_count == 0
    assert media.unreferenced_at is not None

    assert blob.object_id == media.media_id
    assert blob.size == 4096
    assert blob.status == "VERIFIED"
    assert blob.storage_key.startswith("media/user/")

    assert len(variants) == 1
    variant = variants[0]
    assert variant.kind == VariantKind.ORIGINAL.value
    assert variant.status == VariantStatus.READY.value
    assert variant.is_primary is True
    assert variant.blob_id == blob.blob_id


def test_object_stores_metadata_without_reserved_attribute_clash(media_core) -> None:
    repository, factory, _ = media_core
    result = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=MediaKind.IMAGE,
            mime="image/jpeg",
            content=b"x" * 128,
            digest_kind=DigestKind.PLAINTEXT,
            metadata={"source": "gallery", "rotation": 0},
        )
    )
    with factory() as session:
        media = session.get(MediaObject, result.media_id)
    assert media.metadata_json == {"source": "gallery", "rotation": 0}


# --------------------------------------------------------------------------- #
# Digest rules (ADR-002)
# --------------------------------------------------------------------------- #
def test_digest_kinds_never_compare() -> None:
    plaintext = plaintext_digest(b"same bytes")
    ciphertext = ciphertext_digest(b"same bytes")
    assert plaintext.value == ciphertext.value  # same bytes happen to hash the same
    with pytest.raises(CrossKindDigestComparison):
        _ = plaintext == ciphertext
    with pytest.raises(CrossKindDigestComparison):
        _ = plaintext == Digest(kind=DigestKind.PLAINTEXT, value=ciphertext.value, version=2)


def test_digest_equality_inside_one_kind() -> None:
    assert plaintext_digest(b"payload") == plaintext_digest(b"payload")
    assert plaintext_digest(b"payload") != plaintext_digest(b"other")


def test_digest_rejects_malformed_values() -> None:
    with pytest.raises(AppError) as error:
        Digest(kind=DigestKind.PLAINTEXT, value="not-a-digest")
    assert error.value.code == "MEDIA_DIGEST_INVALID"


def test_transport_digest_cannot_become_an_object_identity(media_core) -> None:
    repository, _, _ = media_core
    with pytest.raises(AppError) as error:
        _ingest(repository, digest_kind=DigestKind.TRANSPORT)
    assert error.value.code == "MEDIA_DIGEST_KIND_INVALID"


def test_transport_claim_is_verified_not_trusted(media_core) -> None:
    repository, _, _ = media_core
    good = transport_digest(b"payload")
    repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="moments",
            kind=MediaKind.FILE,
            mime="text/plain",
            content=b"payload",
            digest_kind=DigestKind.PLAINTEXT,
            transport_claim=good,
        )
    )
    with pytest.raises(AppError) as error:
        repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.FILE,
                mime="text/plain",
                content=b"payload",
                digest_kind=DigestKind.PLAINTEXT,
                transport_claim=transport_digest(b"different"),
            )
        )
    assert error.value.code == "MEDIA_TRANSPORT_DIGEST_MISMATCH"


def test_client_plaintext_claim_is_not_an_accepted_kind(media_core) -> None:
    """A client may only declare a transport digest; anything else is rejected."""

    repository, _, _ = media_core
    with pytest.raises(AppError) as error:
        repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.FILE,
                mime="text/plain",
                content=b"payload",
                digest_kind=DigestKind.PLAINTEXT,
                transport_claim=plaintext_digest(b"payload"),
            )
        )
    assert error.value.code == "MEDIA_DIGEST_KIND_INVALID"


# --------------------------------------------------------------------------- #
# Isolation rules (ADR-001)
# --------------------------------------------------------------------------- #
def test_plaintext_objects_are_per_owner_and_never_global() -> None:
    assert allow_cross_user_plaintext_dedup() is False
    assert assert_object_domain(DigestKind.PLAINTEXT, "user:user-a") is IsolationDomain.USER
    with pytest.raises(IsolationViolation):
        assert_object_domain(DigestKind.PLAINTEXT, "e2ee:ciphertext-v1")
    with pytest.raises(IsolationViolation):
        assert_object_domain(DigestKind.CIPHERTEXT, "user:user-a")


def test_second_user_does_not_reuse_another_users_plaintext_object(media_core) -> None:
    repository, factory, _ = media_core
    first = _ingest(repository, owner="user-a", content=b"same bytes" * 100)
    second = _ingest(repository, owner="user-b", content=b"same bytes" * 100)

    assert first.media_id != second.media_id
    assert first.blob_id != second.blob_id
    with factory() as session:
        blobs = list(session.scalars(select(MediaBlob)))
    assert {blob.owner_scope for blob in blobs} == {"user:user-a", "user:user-b"}


def test_same_owner_plaintext_reuses_blob_but_keeps_separate_objects(media_core) -> None:
    """Per-owner dedup saves bytes without merging two logical media."""

    repository, factory, _ = media_core
    first = _ingest(repository, owner="user-a", content=b"identical" * 512)
    second = _ingest(repository, owner="user-a", content=b"identical" * 512)

    assert first.blob_id == second.blob_id
    assert first.media_id != second.media_id
    with factory() as session:
        assert len(list(session.scalars(select(MediaBlob)))) == 1


def test_e2ee_ciphertext_reuse_shares_one_object_across_users(media_core) -> None:
    repository, factory, _ = media_core
    ciphertext = b"ciphertext-bytes" * 20000  # 320 KiB: above the dedup threshold
    first = _ingest(
        repository,
        owner="user-a",
        kind=MediaKind.VIDEO,
        mime="video/mp4",
        content=ciphertext,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.DETERMINISTIC_V1,
    )
    second = _ingest(
        repository,
        owner="user-b",
        kind=MediaKind.VIDEO,
        mime="video/mp4",
        content=ciphertext,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.DETERMINISTIC_V1,
    )

    assert second.reused_object is True
    assert second.media_id == first.media_id
    assert second.blob_id == first.blob_id
    with factory() as session:
        assert len(list(session.scalars(select(MediaObject)))) == 1


def test_random_envelope_never_reuses(media_core) -> None:
    repository, factory, _ = media_core
    payload = b"random-envelope" * 4096
    first = _ingest(
        repository,
        kind=MediaKind.VIDEO,
        mime="video/mp4",
        content=payload,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.RANDOM,
    )
    second = _ingest(
        repository,
        kind=MediaKind.VIDEO,
        mime="video/mp4",
        content=payload,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.RANDOM,
    )
    assert first.media_id != second.media_id
    assert first.blob_id != second.blob_id
    with factory() as session:
        assert len(list(session.scalars(select(MediaBlob)))) == 2


def test_small_ciphertext_is_not_cross_user_deduplicated(media_core) -> None:
    """Below the threshold the confirmation-attack surface is not worth the saving."""

    repository, _, _ = media_core
    tiny = b"tiny"
    first = _ingest(
        repository,
        kind=MediaKind.IMAGE,
        content=tiny,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.DETERMINISTIC_V1,
    )
    second = _ingest(
        repository,
        owner="user-b",
        kind=MediaKind.IMAGE,
        content=tiny,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope=EnvelopeMode.DETERMINISTIC_V1,
    )
    assert first.blob_id != second.blob_id


# --------------------------------------------------------------------------- #
# Storage keys
# --------------------------------------------------------------------------- #
def test_storage_keys_encode_the_isolation_domain() -> None:
    key = storage_key_for(
        isolation_domain=IsolationDomain.USER,
        scope_key="user:user-a",
        blob_id="blob-1",
        mime="image/jpeg",
        kind=MediaKind.IMAGE,
    )
    assert key.startswith("media/user/")
    assert key.endswith(".jpg")
    assert "user-a" not in key  # scope hash only: no raw ids in paths
    assert key_belongs_to_domain(key, digest_kind=DigestKind.PLAINTEXT, owner_scope="user:user-a")
    assert not key_belongs_to_domain(
        key, digest_kind=DigestKind.CIPHERTEXT, owner_scope="e2ee:ciphertext-v1"
    )


def test_e2ee_and_public_keys_use_their_own_segments() -> None:
    e2ee_key = storage_key_for(
        isolation_domain=IsolationDomain.E2EE,
        scope_key="e2ee:ciphertext-v1",
        blob_id="blob-2",
        mime="video/mp4",
        kind=MediaKind.VIDEO,
    )
    public_key = storage_key_for(
        isolation_domain=IsolationDomain.SYSTEM_PUBLIC,
        scope_key="system:public:v1",
        blob_id="blob-3",
        mime="image/png",
        kind=MediaKind.IMAGE,
    )
    assert e2ee_key.startswith("media/e2ee/") and e2ee_key.endswith(".mp4")
    assert public_key.startswith("media/public/") and public_key.endswith(".png")


def test_blob_backend_rejects_path_traversal(tmp_path) -> None:
    backend = LocalBlobBackend(root=str(tmp_path / "root"))
    with pytest.raises(AppError) as error:
        backend.put("../escape.bin", b"x")
    assert error.value.code == "MEDIA_STORAGE_KEY_INVALID"


# --------------------------------------------------------------------------- #
# Metrics and policy
# --------------------------------------------------------------------------- #
def test_metrics_cover_required_observations_and_carry_no_pii() -> None:
    metrics = MediaPlatformMetrics()
    metrics.increment("cache_hit")
    metrics.observe_ms("media_resolve_ms", 4.2)
    line = metrics.debug_line()
    for required in ("media_resolve_ms", "variant_resolve_ms", "authorization_ms", "storage_read_ms"):
        assert required in line
    assert "cache_hit" in line
    for forbidden in ("user-a", "room", "event", "@", "mxc://", "token"):
        assert forbidden not in line


def test_ttl_policy_keeps_the_frozen_ordering() -> None:
    policy = MediaTtlPolicy()
    poster = policy.ttl_seconds(visibility=VisibilityTier.AUDIENCE, variant_kind=VariantKind.POSTER)
    image = policy.ttl_seconds(visibility=VisibilityTier.AUDIENCE, variant_kind=VariantKind.COMPRESSED)
    video = policy.ttl_seconds(visibility=VisibilityTier.AUDIENCE, variant_kind=VariantKind.P720)
    original = policy.ttl_seconds(visibility=VisibilityTier.AUDIENCE, variant_kind=VariantKind.ORIGINAL)
    assert poster >= image >= video >= original

    private = policy.ttl_seconds(visibility=VisibilityTier.PRIVATE, variant_kind=VariantKind.POSTER)
    audience = policy.ttl_seconds(visibility=VisibilityTier.AUDIENCE, variant_kind=VariantKind.POSTER)
    public = policy.ttl_seconds(visibility=VisibilityTier.PUBLIC, variant_kind=VariantKind.POSTER)
    assert public >= audience >= private


def test_variant_preference_adapts_to_network_and_preference() -> None:
    slow = variant_preference_order(
        media_kind=MediaKind.VIDEO, prefer=VariantPreference.AUTO, network=NetworkHint.SLOW
    )
    wifi = variant_preference_order(
        media_kind=MediaKind.VIDEO, prefer=VariantPreference.AUTO, network=NetworkHint.WIFI
    )
    assert slow[0] is VariantKind.POSTER and slow[1] is VariantKind.PREVIEW_VIDEO
    assert wifi.index(VariantKind.P720) < wifi.index(VariantKind.P360)
    assert slow.index(VariantKind.P360) < slow.index(VariantKind.P720)

    quality = variant_preference_order(
        media_kind=MediaKind.IMAGE, prefer=VariantPreference.QUALITY, network=NetworkHint.WIFI
    )
    saver = variant_preference_order(
        media_kind=MediaKind.IMAGE, prefer=VariantPreference.DATA_SAVER, network=NetworkHint.SLOW
    )
    assert quality[0] is VariantKind.ORIGINAL
    assert saver[0] is VariantKind.THUMBNAIL


def test_dedup_policy_refuses_cross_user_plaintext_even_if_configured() -> None:
    """Flipping the frozen flag fails loudly instead of enabling global dedup."""

    from app.modules.media.domain import IsolationViolation

    policy = MediaDedupPolicy(allow_cross_user_plaintext=True)
    with pytest.raises(IsolationViolation):
        policy.decide(
            digest_kind=DigestKind.PLAINTEXT,
            envelope_mode=EnvelopeMode.NONE,
            envelope_version=1,
            size=4096,
        )
    assert allow_cross_user_plaintext_dedup() is False


def test_orphan_grace_deadline_is_in_the_past() -> None:
    from app.modules.media.repository import orphan_grace_deadline

    now = datetime.now(timezone.utc)
    assert orphan_grace_deadline(now, grace_seconds=60) < now
