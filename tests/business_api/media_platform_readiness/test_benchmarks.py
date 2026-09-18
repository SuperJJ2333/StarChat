"""Part 5 — performance benchmarks (Benchmark 001…004).

**These are real measurements**, taken in-process on the same harness the functional suites
use: CPython 3.12, SQLite (in-memory, single connection) and a local filesystem on the
verification workstation. They are *relative* indicators and a regression baseline — they
are **not** production capacity numbers (no HTTP server, no PostgreSQL, no CDN, no network,
no concurrent load). Every number printed here is whatever the machine actually produced;
nothing is estimated.

Run with ``-s`` to see the per-benchmark lines.
"""

from __future__ import annotations

import statistics
import time
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from app.modules.media.authorization import GrantAuthorizer
from app.modules.media.domain import (
    BlobStatus,
    DigestKind,
    GcMode,
    MediaKind,
    Permission,
    SubjectType,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.grants import MediaGrantService
from app.modules.media.lifecycle import MediaGarbageCollector
from app.modules.media.models import MediaBlob, MediaObject, MediaReference, MediaVariant
from app.modules.media.policy import (
    MediaPlatformPolicy,
    MediaTtlPolicy,
    NetworkHint,
    VariantPreference,
)
from app.modules.media.repository import IngestRequest, MediaRepository
from app.modules.media.signed_urls import MediaSignedUrlCodec
from app.modules.media.variants import VariantResolver


def _percentiles(samples_ms: list[float]) -> dict[str, float]:
    ordered = sorted(samples_ms)
    return {
        "n": len(ordered),
        "p50": round(statistics.median(ordered), 3),
        "p95": round(ordered[int(len(ordered) * 0.95) - 1], 3),
        "p99": round(ordered[int(len(ordered) * 0.99) - 1], 3),
        "mean": round(statistics.fmean(ordered), 3),
        "max": round(ordered[-1], 3),
    }


def _time(callable_, iterations: int) -> dict[str, float]:
    samples: list[float] = []
    for _ in range(iterations):
        started = time.perf_counter()
        callable_()
        samples.append((time.perf_counter() - started) * 1000.0)
    return _percentiles(samples)


def _seed_media(
    platform,
    count: int,
    *,
    variant_kinds: tuple[VariantKind, ...] = (),
    kind: MediaKind = MediaKind.IMAGE,
    mime: str = "image/jpeg",
) -> list[str]:
    """Create objects directly through the repository (real file writes included)."""

    repository = MediaRepository(platform.factory, backend=platform.backend)
    media_ids: list[str] = []
    now = datetime.now(timezone.utc)
    for index in range(count):
        result = repository.ingest(
            IngestRequest(
                owner_id="user-a",
                origin_domain="moments",
                kind=kind,
                mime=mime,
                content=f"bench-{index}".encode() * 128,
                digest_kind=DigestKind.PLAINTEXT,
                visibility=VisibilityTier.PRIVATE,
            )
        )
        media_ids.append(result.media_id)
        for extra in variant_kinds:
            with platform.factory.begin() as session:
                session.add(
                    MediaVariant(
                        variant_id=str(uuid4()),
                        media_id=result.media_id,
                        kind=extra.value,
                        blob_id=result.blob_id,
                        status="ready",
                        generation=1,
                        size=1024,
                        mime=mime,
                        created_at=now,
                        ready_at=now,
                    )
                )
    return media_ids


# --------------------------------------------------------------------------- #
# Benchmark 001 — media resolve
# --------------------------------------------------------------------------- #
def test_benchmark_001_media_resolve(platform) -> None:
    media_ids = _seed_media(platform, 200)
    repository = MediaRepository(platform.factory, backend=platform.backend)
    gateway = _business_gateway(platform, repository)

    def resolve_one() -> None:
        gateway.resolve(media_ids[_cursor[0] % len(media_ids)], subject_id="user-a")

    _cursor = [0]

    def timed_resolve() -> None:
        resolve_one()
        _cursor[0] += 1

    result = _time(timed_resolve, 1000)
    print(f"\nBenchmark 001 Media resolve (gateway, 1000 calls): {result}")
    # A single in-process resolve must stay far away from a request-sized budget.
    assert result["p95"] < 50.0, result


# --------------------------------------------------------------------------- #
# Benchmark 002 — authorization + signed URL
# --------------------------------------------------------------------------- #
def test_benchmark_002_authorization_and_signed_url(platform) -> None:
    media_id = _seed_media(platform, 1)[0]
    codec = MediaSignedUrlCodec(secret=platform.settings.media_url_signing_secret)
    grants = MediaGrantService(platform.factory)
    authorizer = GrantAuthorizer(grants=grants, ttl_policy=MediaTtlPolicy())
    media = MediaRepository(platform.factory, backend=platform.backend).get_object(media_id)

    def authorize() -> None:
        authorizer.authorize(
            media=media,
            subject_id="user-a",
            permission=Permission.READ,
            variant_kind=VariantKind.ORIGINAL,
            visibility=VisibilityTier.PRIVATE,
        )

    auth_result = _time(authorize, 1000)
    print(f"\nBenchmark 002a Authorization (owner path, 1000 calls): {auth_result}")

    def mint() -> None:
        codec.mint(
            media_id=media_id,
            variant_kind=VariantKind.ORIGINAL,
            subject="user-a",
            tier=VisibilityTier.PRIVATE,
            ttl_seconds=60,
        )

    mint_result = _time(mint, 1000)
    print(f"Benchmark 002b Signed URL mint (1000 calls): {mint_result}")

    token, _ = codec.mint(
        media_id=media_id,
        variant_kind=VariantKind.ORIGINAL,
        subject="user-a",
        tier=VisibilityTier.PRIVATE,
        ttl_seconds=60,
    )
    verify_result = _time(lambda: codec.verify(token, caller_id="user-a"), 1000)
    print(f"Benchmark 002c Signed URL verify (1000 calls): {verify_result}")

    # Grant-backed authorization (the audience/grant path) is the more expensive decision.
    grants.issue(
        media_id=media_id,
        actor_id="user-a",
        subject_type=SubjectType.USER,
        subject_id="user-b",
        permission=Permission.READ,
        ttl_seconds=600,
    )

    def authorize_grant() -> None:
        authorizer.authorize(
            media=media,
            subject_id="user-b",
            permission=Permission.READ,
            variant_kind=VariantKind.ORIGINAL,
            visibility=VisibilityTier.PRIVATE,
        )

    grant_result = _time(authorize_grant, 500)
    print(f"Benchmark 002d Authorization (grant path, 500 calls): {grant_result}")

    for result in (auth_result, mint_result, verify_result, grant_result):
        assert result["p95"] < 50.0, result


# --------------------------------------------------------------------------- #
# Benchmark 003 — variant resolver
# --------------------------------------------------------------------------- #
def test_benchmark_003_variant_resolver(platform) -> None:
    """Image (thumbnail / original) and video (poster / 720p / original) selection."""

    image_id = _seed_media(
        platform,
        1,
        variant_kinds=(VariantKind.THUMBNAIL, VariantKind.PREVIEW),
    )[0]
    video_id = _seed_media(
        platform,
        1,
        variant_kinds=(
            VariantKind.POSTER,
            VariantKind.PREVIEW_VIDEO,
            VariantKind.P360,
            VariantKind.P720,
        ),
        kind=MediaKind.VIDEO,
        mime="video/mp4",
    )[0]
    repository = MediaRepository(platform.factory, backend=platform.backend)
    resolver = VariantResolver(repository)

    cases = [
        # (label, media_id, kind, prefer, network, allowed_kinds, expected)
        ("image/slow -> thumbnail", image_id, MediaKind.IMAGE, VariantPreference.AUTO, NetworkHint.SLOW,
         frozenset({VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.ORIGINAL}), VariantKind.THUMBNAIL),
        ("image/wifi-auto -> thumbnail", image_id, MediaKind.IMAGE, VariantPreference.AUTO, NetworkHint.WIFI,
         frozenset({VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.ORIGINAL}), VariantKind.THUMBNAIL),
        ("image/wifi-quality -> original", image_id, MediaKind.IMAGE, VariantPreference.QUALITY, NetworkHint.WIFI,
         frozenset({VariantKind.THUMBNAIL, VariantKind.PREVIEW, VariantKind.ORIGINAL}), VariantKind.ORIGINAL),
        ("image/data-saver -> thumbnail", image_id, MediaKind.IMAGE, VariantPreference.DATA_SAVER, NetworkHint.SLOW,
         frozenset({VariantKind.THUMBNAIL, VariantKind.ORIGINAL}), VariantKind.THUMBNAIL),
        ("video/only-poster-ready -> poster", video_id, MediaKind.VIDEO, VariantPreference.AUTO, NetworkHint.WIFI,
         frozenset({VariantKind.POSTER}), VariantKind.POSTER),
        ("video/wifi in {360p,720p} -> 720p", video_id, MediaKind.VIDEO, VariantPreference.AUTO, NetworkHint.WIFI,
         frozenset({VariantKind.P360, VariantKind.P720}), VariantKind.P720),
        ("video/slow in {360p,720p} -> 360p", video_id, MediaKind.VIDEO, VariantPreference.AUTO, NetworkHint.SLOW,
         frozenset({VariantKind.P360, VariantKind.P720}), VariantKind.P360),
        ("video/playback-720p -> 720p", video_id, MediaKind.VIDEO, VariantPreference.QUALITY, NetworkHint.WIFI,
         frozenset({VariantKind.P720}), VariantKind.P720),
        ("video/read-original -> original", video_id, MediaKind.VIDEO, VariantPreference.QUALITY, NetworkHint.WIFI,
         frozenset({VariantKind.ORIGINAL}), VariantKind.ORIGINAL),
        # Documented behaviour: with no allow-list the cheapest ready variant wins, so the
        # preference/network hints only reorder *within* an allowed set (finding M2).
        ("video/no-filter/wifi -> poster (cheapest ready)", video_id, MediaKind.VIDEO, VariantPreference.AUTO,
         NetworkHint.WIFI, None, VariantKind.POSTER),
    ]

    print("\nBenchmark 003 Variant resolver (500 calls each):")
    for label, media_id, media_kind, prefer, network, allowed, expected in cases:
        chosen = resolver.best(
            media_id, media_kind=media_kind, prefer=prefer, network=network, allowed_kinds=allowed
        )
        assert chosen is not None, label
        assert chosen.kind is expected, f"{label}: expected {expected}, got {chosen.kind}"
        result = _time(
            lambda mid=media_id, k=media_kind, p=prefer, n=network, a=allowed: resolver.best(
                mid, media_kind=k, prefer=p, network=n, allowed_kinds=a
            ),
            500,
        )
        print(f"  {label}: {result}")
        assert result["p95"] < 50.0, (label, result)

def test_benchmark_004_gc_with_ten_thousand_references(platform) -> None:
    objects = 1000
    references_per_object = 10
    media_ids = _seed_media(platform, objects)
    now = datetime.now(timezone.utc)

    rows: list[dict] = []
    for media_id in media_ids:
        for index in range(references_per_object):
            rows.append(
                {
                    "reference_id": str(uuid4()),
                    "media_id": media_id,
                    "owner_id": "user-a",
                    "variant_kind": None,
                    "business_type": "moment",
                    "business_id": f"{media_id}:{index}",
                    "room_ref": None,
                    "permission_scope": "private",
                    "ref_kind": "observed",
                    "state": "active",
                    "created_at": now,
                    "released_at": None,
                    "release_reason": None,
                }
            )
    from sqlalchemy import insert, update

    started = time.perf_counter()
    with platform.factory.begin() as session:
        for offset in range(0, len(rows), 5000):
            session.execute(insert(MediaReference), rows[offset : offset + 5000])
        session.execute(
            update(MediaObject).values(ref_count=references_per_object, status="ACTIVE", unreferenced_at=None)
        )
    insert_ms = (time.perf_counter() - started) * 1000.0

    collector = MediaGarbageCollector(
        platform.factory,
        backend=platform.backend,
        policy=MediaPlatformPolicy(orphan_grace_seconds=0),
    )
    dry = _time(lambda: collector.run(mode=GcMode.DRY_RUN, limit=1000), 1)
    print(
        f"\nBenchmark 004 GC with {objects * references_per_object} references "
        f"({objects} objects): insert={insert_ms:.1f} ms dry_run={dry}"
    )

    # All 1000 objects are referenced ten times, so nothing may be collected.
    report = collector.run(mode=GcMode.ENFORCE, limit=1000)
    assert report.collected == 0
    assert report.skipped.get("has_references") == objects
    with platform.factory() as session:
        assert session.query(MediaObject).filter(MediaObject.status == "DELETED").count() == 0
    assert dry["p50"] < 5000.0, dry


def _business_gateway(platform, repository):
    """A gateway wired exactly like production (grant authorizer + audience registry)."""

    from app.modules.media.audience import AudienceRegistry, MomentsAudienceVerifier
    from app.modules.media.gateway import (
        BusinessMediaGateway,
        MediaGatewayRegistry,
        MatrixMediaGateway,
    )

    policy = MediaPlatformPolicy()
    grants = MediaGrantService(platform.factory)
    authorizer = GrantAuthorizer(grants=grants, ttl_policy=policy.ttl)
    resolver = VariantResolver(repository)
    registry = MediaGatewayRegistry(
        matrix=MatrixMediaGateway(),
        business=BusinessMediaGateway(
            repository=repository, resolver=resolver, authorizer=authorizer, policy=policy
        ),
    )
    return registry.business
