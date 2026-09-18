"""Concurrency-race regressions (found by the real-PostgreSQL deployment rehearsal).

Two partial unique indexes make the media platform safe under concurrency, and both must be
*survivable* rather than fatal:

* ``uq_media_objects_digest_slot`` — only a reusable object reserves its digest slot (ADR-002);
* ``uq_media_references_active`` — only an active reference is unique, which is what makes
  re-attaching idempotent (ADR-006 / phase 3 freeze §4.6).

A single SQLite process without foreign keys never produced these races, so the rehearsal did:
against real PostgreSQL, four concurrent ciphertext ingests failed three times with a raw
``IntegrityError``, and four concurrent attaches failed three times the same way. Losing the
race is not an error — it means another request already did the work — so both paths converge
on the winner. These tests reproduce the losing interleaving deterministically.
"""

from __future__ import annotations

from pathlib import Path

from app.modules.media.domain import (
    BusinessType,
    DigestKind,
    EnvelopeMode,
    MediaKind,
)
from app.modules.media.policy import DedupDecision, MediaDedupPolicy
from app.modules.media.references import MediaReferenceService
from app.modules.media.repository import IngestRequest, MediaRepository

# Above the 256 KiB dedup threshold, so these bytes reserve a digest slot.
CIPHERTEXT = b"race-ciphertext" * 20_000


class _NeverReuse(MediaDedupPolicy):
    """The losing interleaving: the dedup lookup ran before the winner committed."""

    def decide(self, **kwargs) -> DedupDecision:  # type: ignore[override]
        return DedupDecision.CREATE


def _ingest_request(content: bytes, owner: str) -> IngestRequest:
    return IngestRequest(
        owner_id=owner,
        origin_domain="chat",
        kind=MediaKind.VIDEO,
        mime="video/mp4",
        content=content,
        digest_kind=DigestKind.CIPHERTEXT,
        envelope_mode=EnvelopeMode.DETERMINISTIC_V1,
    )


def _platform_files(root: str) -> list[str]:
    base = Path(root) / "media"
    if not base.is_dir():
        return []
    return [str(path) for path in sorted(base.rglob("*")) if path.is_file()]


def test_ingest_converges_when_it_loses_the_digest_slot_race(platform) -> None:
    winner = MediaRepository(platform.factory, backend=platform.backend).ingest(
        _ingest_request(CIPHERTEXT, owner="user-a")
    )
    assert winner.reused_object is False

    loser = MediaRepository(
        platform.factory, backend=platform.backend, dedup_policy=_NeverReuse()
    ).ingest(_ingest_request(CIPHERTEXT, owner="user-b"))

    # The loser must converge on the winner's object instead of raising, and the bytes it had
    # already written must not be left behind as an orphan.
    assert loser.media_id == winner.media_id
    assert loser.blob_id == winner.blob_id
    assert loser.reused_object is True
    assert loser.reused_blob is True
    assert len(_platform_files(platform.root)) == 1


def test_attach_converges_when_it_loses_the_active_reference_race(platform, monkeypatch) -> None:
    media_id = platform.ingest(content=b"reference-race" * 64).media_id
    winner = MediaReferenceService(platform.factory).attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="race-moment",
    )

    # Simulate the losing interleaving: the first read misses (it ran before the winner
    # committed), so the insert hits uq_media_references_active; the recovery read must then
    # see the winner's row.
    original = MediaReferenceService._find_active_reference
    seen = {"reads": 0}

    def stale_first_read(session, **kwargs):
        seen["reads"] += 1
        if seen["reads"] == 1:
            return None
        return original(session, **kwargs)

    monkeypatch.setattr(
        MediaReferenceService, "_find_active_reference", staticmethod(stale_first_read)
    )
    service = MediaReferenceService(platform.factory)
    loser = service.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="race-moment",
    )

    assert seen["reads"] >= 2, "the recovery read must have run"
    assert loser.reference_id == winner.reference_id
    assert service.recount(media_id) == 1


def test_grant_issue_converges_when_it_loses_the_active_grant_race(platform, monkeypatch) -> None:
    from app.modules.media.domain import Permission, SubjectType
    from app.modules.media.grants import MediaGrantService

    media_id = platform.ingest(content=b"grant-race" * 64).media_id
    winner = MediaGrantService(platform.factory).issue(
        media_id=media_id,
        actor_id="user-a",
        subject_type=SubjectType.USER,
        subject_id="user-b",
        permission=Permission.READ,
        ttl_seconds=600,
    )

    original = MediaGrantService._find_active_grant
    seen = {"reads": 0}

    def stale_first_read(session, **kwargs):
        seen["reads"] += 1
        if seen["reads"] == 1:
            return None
        return original(session, **kwargs)

    monkeypatch.setattr(
        MediaGrantService, "_find_active_grant", staticmethod(stale_first_read)
    )
    service = MediaGrantService(platform.factory)
    loser = service.issue(
        media_id=media_id,
        actor_id="user-a",
        subject_type=SubjectType.USER,
        subject_id="user-b",
        permission=Permission.READ,
        ttl_seconds=600,
    )

    assert seen["reads"] >= 2, "the recovery read must have run"
    assert loser.grant_id == winner.grant_id
    assert len(service.list_for_media(media_id)) == 1
