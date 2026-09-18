"""Part 7 — large-scale simulations (Scenario 001…003).

These are **simulated** scales on the local harness (SQLite in-memory, single process, local
disk). They answer "does the design still behave at size, and where does it stop behaving",
not "does production hold 1000 users". Any target the machine could not reach is reported as
NOT MEASURED rather than extrapolated.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import func, insert, select

from app.modules.media.audience import AudienceRegistry, MomentsAudienceVerifier
from app.modules.media.domain import (
    BlobStatus,
    GcMode,
    MediaStatus,
)
from app.modules.media.lifecycle import MediaGarbageCollector
from app.modules.media.models import MediaBlob, MediaObject, MediaReference
from app.modules.media.policy import MediaPlatformPolicy

REFERENCE_BATCH = 25_000


# --------------------------------------------------------------------------- #
# Scenario 001 — 1000 users × 1000 references
# --------------------------------------------------------------------------- #
def test_scenario_001_one_million_references_are_queryable(platform) -> None:
    """Target: 1,000,000 active references across 1,000 users (1,000 each)."""

    users = 1000
    per_user = 1000
    target = users * per_user
    now = datetime.now(timezone.utc)

    # 200 shared objects keep the object side small while the reference side is at target
    # scale: the scenario is about reference volume, and this isolates that cost.
    object_ids: list[str] = []
    with platform.factory.begin() as session:
        for index in range(200):
            media_id = str(uuid4())
            object_ids.append(media_id)
            session.add(
                MediaObject(
                    media_id=media_id,
                    owner_id=f"user-{index % users}",
                    owner_scope=f"user:user-{index % users}",
                    isolation_domain="user",
                    origin_domain="moments",
                    kind="image",
                    canonical_mime="image/jpeg",
                    canonical_size=2048,
                    digest_kind="plaintext_digest",
                    digest_version=1,
                    content_digest=f"{index:064x}",
                    envelope_mode="none",
                    envelope_version=1,
                    dedup_eligible=False,
                    status=MediaStatus.ACTIVE.value,
                    visibility_hint="private",
                    ref_count=0,
                    created_at=now,
                    ready_at=now,
                    unreferenced_at=now,
                )
            )

    started = time.perf_counter()
    written = 0
    for user_index in range(users):
        batch: list[dict] = []
        for ref_index in range(per_user):
            batch.append(
                {
                    "reference_id": str(uuid4()),
                    "media_id": object_ids[(user_index + ref_index) % len(object_ids)],
                    "owner_id": f"user-{user_index}",
                    "variant_kind": None,
                    "business_type": "moment",
                    "business_id": f"m-{user_index}-{ref_index}",
                    "room_ref": None,
                    "permission_scope": "private",
                    "ref_kind": "observed",
                    "state": "active",
                    "created_at": now,
                    "released_at": None,
                    "release_reason": None,
                }
            )
            if len(batch) >= REFERENCE_BATCH:
                with platform.factory.begin() as session:
                    session.execute(insert(MediaReference), batch)
                written += len(batch)
                batch = []
        if batch:
            with platform.factory.begin() as session:
                session.execute(insert(MediaReference), batch)
            written += len(batch)
    insert_seconds = time.perf_counter() - started

    with platform.factory() as session:
        total = session.scalar(select(func.count()).select_from(MediaReference))
        first_user = session.scalar(
            select(func.count())
            .select_from(MediaReference)
            .where(MediaReference.owner_id == "user-0")
        )
        busiest_object = session.scalar(
            select(func.count())
            .select_from(MediaReference)
            .where(MediaReference.media_id == object_ids[0])
        )

    print(
        f"\nScenario 001: {written} references in {insert_seconds:.1f}s "
        f"(target {target}); per-user query={first_user}; per-object query={busiest_object}"
    )
    assert written == target
    assert total == target
    assert first_user == per_user

    # The indexed lookups the platform actually performs stay fast at this size.
    started = time.perf_counter()
    with platform.factory() as session:
        for _ in range(100):
            session.scalar(
                select(func.count())
                .select_from(MediaReference)
                .where(
                    MediaReference.media_id == object_ids[0],
                    MediaReference.state == "active",
                )
            )
    per_query_ms = (time.perf_counter() - started) * 1000.0 / 100
    print(f"Scenario 001: active-reference count query = {per_query_ms:.2f} ms average")
    assert per_query_ms < 50.0

    # A scoped GC run must stay bounded: it only inspects its limit, not the whole table.
    collector = MediaGarbageCollector(
        platform.factory,
        backend=platform.backend,
        policy=MediaPlatformPolicy(orphan_grace_seconds=0),
    )
    started = time.perf_counter()
    report = collector.run(mode=GcMode.DRY_RUN, limit=200)
    gc_ms = (time.perf_counter() - started) * 1000.0
    print(f"Scenario 001: GC dry-run over 200 objects = {gc_ms:.1f} ms")
    assert report.scanned <= 200


# --------------------------------------------------------------------------- #
# Scenario 002 — a hot moment read 10 000 times
# --------------------------------------------------------------------------- #
def test_scenario_002_hot_moment_authorization(platform) -> None:
    """10,000 authorization evaluations for a popular moment's audience."""

    from app.modules.friendship.models import Friendship
    from app.modules.moments.models import Moment

    reads = 10_000
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
                text="hot moment",
                visibility="PUBLIC",
                image_urls=[],
                include_user_ids=[],
                exclude_user_ids=[],
                include_tag_ids=[],
                exclude_tag_ids=[],
                location=None,
                link_url=None,
                status="PUBLISHED",
                idempotency_key="hot-moment",
                created_at=now,
                deleted_at=None,
            )
        )

    registry = AudienceRegistry(
        verifiers=(MomentsAudienceVerifier(platform.factory),)
    )
    audience_ref = f"moment:{moment_id}"
    assert registry.verify(audience_ref, caller_id="user-b") is True

    started = time.perf_counter()
    allowed = 0
    for _ in range(reads):
        if registry.verify(audience_ref, caller_id="user-b"):
            allowed += 1
    elapsed = time.perf_counter() - started
    per_read_ms = elapsed * 1000.0 / reads
    print(
        f"\nScenario 002: {reads} audience authorizations in {elapsed:.2f}s "
        f"({per_read_ms:.3f} ms each), allowed={allowed}"
    )
    assert allowed == reads

    # A non-member must consistently be refused at the same scale.
    refused = sum(
        1 for _ in range(200) if not registry.verify(audience_ref, caller_id="user-c")
    )
    assert refused == 200


# --------------------------------------------------------------------------- #
# Scenario 003 — a large orphan backlog
# --------------------------------------------------------------------------- #
def test_scenario_003_gc_handles_a_large_orphan_backlog(platform) -> None:
    """2,000 orphaned objects collected in one bounded pass, without touching live media."""

    from app.modules.media.repository import IngestRequest, MediaRepository
    from app.modules.media.domain import DigestKind, MediaKind

    orphans = 2000
    live = 50
    repository = MediaRepository(platform.factory, backend=platform.backend)
    orphan_ids: list[str] = []
    for index in range(orphans):
        result = repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.IMAGE,
                mime="image/jpeg",
                content=f"orphan-{index}".encode() * 64,
                digest_kind=DigestKind.PLAINTEXT,
            )
        )
        orphan_ids.append(result.media_id)
    live_ids: list[str] = []
    for index in range(live):
        result = repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=MediaKind.IMAGE,
                mime="image/jpeg",
                content=f"live-{index}".encode() * 64,
                digest_kind=DigestKind.PLAINTEXT,
            )
        )
        live_ids.append(result.media_id)
        from app.modules.media.domain import BusinessType
        from app.modules.media.references import MediaReferenceService

        MediaReferenceService(platform.factory).attach(
            media_id=result.media_id,
            actor_id="user-a",
            business_type=BusinessType.MOMENT,
            business_id=f"live-moment-{index}",
        )

    collector = MediaGarbageCollector(
        platform.factory,
        backend=platform.backend,
        policy=MediaPlatformPolicy(orphan_grace_seconds=0),
    )
    started = time.perf_counter()
    report = collector.run(mode=GcMode.ENFORCE, limit=orphans + live)
    elapsed = time.perf_counter() - started
    print(
        f"\nScenario 003: {report.collected} orphans collected in {elapsed:.1f}s "
        f"({report.bytes_reclaimed} bytes), skipped={report.skipped}"
    )

    with platform.factory() as session:
        deleted = session.scalar(
            select(func.count())
            .select_from(MediaObject)
            .where(MediaObject.status == MediaStatus.DELETED.value)
        )
        remaining_live = session.scalar(
            select(func.count())
            .select_from(MediaObject)
            .where(
                MediaObject.media_id.in_(live_ids),
                MediaObject.status != MediaStatus.DELETED.value,
            )
        )
        blobs_deleted = session.scalar(
            select(func.count())
            .select_from(MediaBlob)
            .where(MediaBlob.status == BlobStatus.DELETED.value)
        )

    assert report.collected == orphans
    assert deleted == orphans
    assert remaining_live == live  # live media untouched
    assert blobs_deleted == orphans
    assert Path(platform.root).exists()

    # Running again on an empty backlog is a cheap no-op (stability).
    started = time.perf_counter()
    second = collector.run(mode=GcMode.ENFORCE, limit=200)
    second_ms = (time.perf_counter() - started) * 1000.0
    print(f"Scenario 003: second pass collected={second.collected} in {second_ms:.1f} ms")
    assert second.collected == 0
