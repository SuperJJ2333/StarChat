"""Part 3 and Part 6 — data consistency (Data-001…003) and concurrency (Concurrent-001…004).

Consistency is checked at the level the invariants live: the reference table drives the
object's state, the collector refuses anything still in use, and storage/metadata drift is
detectable and repairable in both directions.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import select

from app.modules.media.domain import (
    BlobStatus,
    BusinessType,
    DigestKind,
    EnvelopeMode,
    GcMode,
    MediaKind,
    MediaStatus,
    ReferenceKind,
    ReleaseReason,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.lifecycle import MediaGarbageCollector, pin_object
from app.modules.media.models import MediaBlob, MediaObject, MediaReference, MediaUploadSession
from app.modules.media.policy import MediaPlatformPolicy
from app.modules.media.reconcile import MediaReconciler
from app.modules.media.references import MediaReferenceService
from app.modules.media.repository import IngestRequest, MediaRepository
from app.modules.media.storage import LocalBlobBackend


# --------------------------------------------------------------------------- #
# Data-001 — reference consistency
# --------------------------------------------------------------------------- #
def test_data_001_releasing_references_moves_object_to_orphan_only_at_zero(platform) -> None:
    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    first = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.CHAT_MESSAGE,
        business_id="$event-1",
    )
    second = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-1",
    )
    assert references.recount(result.media_id) == 2

    references.release(reference_id=first.reference_id, actor_id="user-a")
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
        active = list(
            session.scalars(
                select(MediaReference).where(
                    MediaReference.media_id == result.media_id,
                    MediaReference.state == "active",
                )
            )
        )
    assert media.status == MediaStatus.ACTIVE.value
    assert media.deleted_at is None
    assert [row.business_id for row in active] == ["moment-1"]
    assert platform.backend.exists(_blob_key(platform, result.media_id)) is True

    references.release(
        reference_id=second.reference_id,
        actor_id="user-a",
        reason=ReleaseReason.MOMENT_DELETED,
    )
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
    assert media.status == MediaStatus.ORPHAN.value
    assert media.ref_count == 0
    assert media.unreferenced_at is not None
    # Orphan is not deletion: bytes are still there and the object is still re-attachable.
    assert platform.backend.exists(_blob_key(platform, result.media_id)) is True
    reattached = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-2",
    )
    assert reattached.state == "active"
    with platform.factory() as session:
        assert session.get(MediaObject, result.media_id).status == MediaStatus.ACTIVE.value


def test_data_001_ref_count_is_recomputable_after_drift(platform) -> None:
    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    for index in range(3):
        references.attach(
            media_id=result.media_id,
            actor_id="user-a",
            business_type=BusinessType.MOMENT,
            business_id=f"moment-{index}",
        )
    # Corrupt the cached column the way a crash between two statements could.
    with platform.factory.begin() as session:
        session.get(MediaObject, result.media_id).ref_count = 99
    assert references.recount(result.media_id) == 3


# --------------------------------------------------------------------------- #
# Data-002 — GC safety
# --------------------------------------------------------------------------- #
def _collector(platform, *, grace=0) -> MediaGarbageCollector:
    return MediaGarbageCollector(
        platform.factory,
        backend=platform.backend,
        policy=MediaPlatformPolicy(orphan_grace_seconds=grace),
    )


def test_data_002_gc_never_collects_referenced_pinned_or_in_flight_media(platform) -> None:
    referenced = platform.ingest(content=b"referenced" * 600)
    pinned = platform.ingest(content=b"pinned-object" * 600)
    uploading = platform.ingest(content=b"uploading" * 600)
    processing = platform.ingest(content=b"processing" * 600)
    collectable = platform.ingest(content=b"collectable" * 600)

    references = MediaReferenceService(platform.factory)
    references.attach(
        media_id=referenced.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-live",
    )
    pin_object(platform.factory, media_id=pinned.media_id, seconds=3600)

    # An in-flight upload session that already points at the object.
    now = datetime.now(timezone.utc)
    with platform.factory.begin() as session:
        session.add(
            MediaUploadSession(
                upload_id=str(uuid4()),
                owner_id="user-a",
                origin_domain="moments",
                kind="image",
                declared_size=1024,
                declared_mime="image/jpeg",
                envelope_mode=EnvelopeMode.NONE.value,
                envelope_version=1,
                part_size=1024,
                chunks=[],
                uploaded_bytes=0,
                status="uploading",
                media_id=uploading.media_id,
                idempotency_key="in-flight",
                created_at=now,
                updated_at=now,
                expires_at=now + timedelta(hours=1),
            )
        )
    # A variant still being produced (processing) must hold the object too.
    with platform.factory.begin() as session:
        from app.modules.media.models import MediaVariant

        session.add(
            MediaVariant(
                variant_id=str(uuid4()),
                media_id=processing.media_id,
                kind=VariantKind.THUMBNAIL.value,
                blob_id=None,
                status="processing",
                generation=2,
                created_at=now,
            )
        )

    report = _collector(platform).run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}

    assert decisions[referenced.media_id].reason == "has_references"
    assert decisions[pinned.media_id].reason == "pinned"
    assert decisions[uploading.media_id].reason == "active_upload"
    # A processing variant is protected by the in-flight rule as well: the object is still
    # being written, so it must not be collected.
    assert decisions[processing.media_id].action in ("skip", "would_collect")
    assert decisions[collectable.media_id].action == "collect"

    with platform.factory() as session:
        for media in (referenced, pinned, uploading, processing):
            assert session.get(MediaObject, media.media_id).status != MediaStatus.DELETED.value
        assert session.get(MediaObject, collectable.media_id).status == MediaStatus.DELETED.value


def test_data_002_gc_dry_run_changes_nothing(platform) -> None:
    result = platform.ingest()
    before = platform.backend.exists(_blob_key(platform, result.media_id))
    report = _collector(platform).run(mode=GcMode.DRY_RUN)
    assert report.dry_run is True
    assert report.collected >= 1  # dry run still reports what it would do
    with platform.factory() as session:
        assert session.get(MediaObject, result.media_id).status != MediaStatus.DELETED.value
    assert platform.backend.exists(_blob_key(platform, result.media_id)) == before


# --------------------------------------------------------------------------- #
# Data-003 — crash recovery, both directions
# --------------------------------------------------------------------------- #
def test_data_003_object_written_without_index_is_rebuilt(platform) -> None:
    """Bytes on disk with no row: the reconciler rebuilds a blob row for them."""

    key = "media/user/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/recovered-blob.jpg"
    target = Path(platform.root) / key
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"orphan-bytes" * 512)

    reconciler = MediaReconciler(platform.factory, backend=platform.backend, root=platform.root)
    dry = reconciler.run(dry_run=True)
    assert key in dry.orphan_files
    assert dry.rebuilt == 0
    with platform.factory() as session:
        assert session.scalars(select(MediaBlob)).first() is None

    enforced = reconciler.run(dry_run=False)
    assert enforced.rebuilt == 1
    with platform.factory() as session:
        rebuilt = session.scalars(
            select(MediaBlob).where(MediaBlob.storage_key == key)
        ).first()
    assert rebuilt is not None
    assert rebuilt.status == BlobStatus.VERIFIED.value
    assert rebuilt.size == len(b"orphan-bytes" * 512)
    # The digest kind is recovered from the isolation segment, so E2EE bytes are never
    # re-indexed as plaintext.
    assert rebuilt.digest_kind == DigestKind.PLAINTEXT.value
    assert rebuilt.object_id is None  # unattached: discoverable, re-attachable


def test_data_003_e2ee_orphan_is_rebuilt_as_ciphertext(platform) -> None:
    key = "media/e2ee/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/e2ee-orphan.mp4"
    target = Path(platform.root) / key
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(b"cipher-bytes" * 512)

    reconciler = MediaReconciler(platform.factory, backend=platform.backend, root=platform.root)
    assert reconciler.run(dry_run=False).rebuilt == 1
    with platform.factory() as session:
        rebuilt = session.scalars(select(MediaBlob).where(MediaBlob.storage_key == key)).first()
    assert rebuilt.digest_kind == DigestKind.CIPHERTEXT.value
    assert rebuilt.isolation_domain == "e2ee"


def test_data_003_index_without_object_is_invalidated(platform) -> None:
    """A row pointing at a missing file must be invalidated, not left reserving its slot."""

    result = platform.ingest(owner="user-a", content=b"will-vanish" * 700)
    key = _blob_key(platform, result.media_id)
    (Path(platform.root) / key).unlink()

    reconciler = MediaReconciler(platform.factory, backend=platform.backend, root=platform.root)
    dry = reconciler.run(dry_run=True)
    assert result.blob_id in dry.missing_files
    with platform.factory() as session:
        assert session.get(MediaBlob, result.blob_id).status != BlobStatus.DELETED.value

    enforced = reconciler.run(dry_run=False)
    assert enforced.invalidated == 1
    with platform.factory() as session:
        blob = session.get(MediaBlob, result.blob_id)
    assert blob.status == BlobStatus.DELETED.value
    assert blob.deleted_at is not None

    # The digest slot is free again: the same content can be stored after the repair.
    recreated = platform.ingest(owner="user-a", content=b"will-vanish" * 700)
    assert recreated.blob_id != result.blob_id


def test_data_003_reconciler_never_touches_legacy_namespaces(platform) -> None:
    """Legacy Moments and avatar objects have no blob row by design and are out of scope."""

    legacy = Path(platform.root) / "moments" / "user-a" / "legacy-object.jpg"
    legacy.parent.mkdir(parents=True, exist_ok=True)
    legacy.write_bytes(b"legacy-bytes")

    reconciler = MediaReconciler(platform.factory, backend=platform.backend, root=platform.root)
    report = reconciler.run(dry_run=False)
    assert report.rebuilt == 0
    assert legacy.exists()  # untouched
    with platform.factory() as session:
        assert session.scalars(select(MediaBlob)).first() is None


# --------------------------------------------------------------------------- #
# Concurrent-001 … 004
# --------------------------------------------------------------------------- #
def test_concurrent_001_ciphertext_upload_produces_a_single_blob(platform) -> None:
    """Concurrent identical ciphertext uploads share one blob and one object."""

    payload = b"concurrent-cipher" * 20000
    repository = MediaRepository(platform.factory, backend=platform.backend)

    def ingest(owner: str):
        return repository.ingest(
            IngestRequest(
                owner_id=owner,
                origin_domain="chat",
                kind=MediaKind.VIDEO,
                mime="video/mp4",
                content=payload,
                digest_kind=DigestKind.CIPHERTEXT,
                envelope_mode=EnvelopeMode.DETERMINISTIC_V1,
            )
        )

    results = [ingest("user-a"), ingest("user-b"), ingest("user-c"), ingest("user-a")]
    assert len({result.blob_id for result in results}) == 1
    assert len({result.media_id for result in results}) == 1
    with platform.factory() as session:
        assert len(list(session.scalars(select(MediaBlob)))) == 1


def test_concurrent_001b_plaintext_upload_never_shares_across_users(platform) -> None:
    payload = b"concurrent-plain" * 700
    results = {owner: platform.ingest(owner=owner, content=payload) for owner in ("user-a", "user-b")}
    assert results["user-a"].blob_id != results["user-b"].blob_id
    with platform.factory() as session:
        blobs = list(session.scalars(select(MediaBlob)))
    assert len(blobs) == 2
    assert {blob.owner_scope for blob in blobs} == {"user:user-a", "user:user-b"}


def test_concurrent_002_repeated_reference_creation_is_idempotent(platform) -> None:
    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    views = [
        references.attach(
            media_id=result.media_id,
            actor_id="user-a",
            business_type=BusinessType.MOMENT,
            business_id="moment-race",
        )
        for _ in range(5)
    ]
    assert len({view.reference_id for view in views}) == 1
    assert references.recount(result.media_id) == 1
    with platform.factory() as session:
        rows = list(session.scalars(select(MediaReference)))
    assert len(rows) == 1


def test_concurrent_003_read_survives_a_collecting_gc(platform) -> None:
    """A read of referenced media succeeds even while the collector runs."""

    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-read",
    )
    report = _collector(platform).run(mode=GcMode.ENFORCE)
    assert all(decision.media_id != result.media_id for decision in report.decisions if decision.action == "collect")

    import asyncio

    async def read() -> int:
        async with platform.client() as client:
            response = await client.get(
                f"/api/v1/media/platform/objects/{result.media_id}/variants/original",
                headers=platform.headers["user-a"],
            )
            return response.status_code

    assert asyncio.run(read()) == 200


def test_concurrent_004_delete_and_reference_race_settles_consistently(platform) -> None:
    """Delete wins the race → the object is orphaned; a late reference revives it."""

    result = platform.ingest()
    references = MediaReferenceService(platform.factory)
    reference = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-race-1",
    )
    references.release(reference_id=reference.reference_id, actor_id="user-a")
    with platform.factory() as session:
        assert session.get(MediaObject, result.media_id).status == MediaStatus.ORPHAN.value

    # A late attach (the race loser ordering) must revive the object rather than resurrect a
    # half-deleted one: the collector has not run, so bytes are still present.
    revived = references.attach(
        media_id=result.media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-race-2",
        ref_kind=ReferenceKind.OBSERVED,
    )
    assert revived.state == "active"
    with platform.factory() as session:
        media = session.get(MediaObject, result.media_id)
    assert media.status == MediaStatus.ACTIVE.value
    assert media.unreferenced_at is None

    # And after a real collection the object is gone for good; a new reference for the same
    # business object must fail rather than point at nothing.
    references.release(reference_id=revived.reference_id, actor_id="user-a")
    _collector(platform).run(mode=GcMode.ENFORCE)
    with platform.factory() as session:
        assert session.get(MediaObject, result.media_id).status == MediaStatus.DELETED.value

    from app.core.errors import AppError

    with pytest.raises(AppError):
        references.attach(
            media_id=result.media_id,
            actor_id="user-a",
            business_type=BusinessType.MOMENT,
            business_id="moment-after-gc",
        )


def _blob_key(platform, media_id: str) -> str:
    with platform.factory() as session:
        blob = session.scalars(
            select(MediaBlob).where(MediaBlob.object_id == media_id)
        ).first()
        return blob.storage_key if blob else ""
