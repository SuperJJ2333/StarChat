"""Media Engine Phase 4.3 / 4.6 — reference lifecycle and garbage collection.

Acceptance coverage:

* Test 2 — two business references (chat + moment) to one object; releasing one leaves the
  object and the other reference intact;
* Test 7 — an unreferenced object becomes an orphan and is collectible after the grace
  period, while a referenced object is never collected;
* security requirement §13 — releasing a reference never deletes another reference's media,
  and another user cannot release someone else's reference;
* dry run changes nothing, enforcement is crash-safe (mark before unlink) and a DELETING
  object is recovered by the next run;
* the GC audit row contains opaque ids only.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from httpx import ASGITransport, AsyncClient
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
    GcSkipReason,
    MediaStatus,
    ReferenceKind,
    ReleaseReason,
    VariantKind,
    VisibilityTier,
)
from app.modules.media.lifecycle import MediaGarbageCollector, pin_object
from app.modules.media.models import MediaBlob, MediaGcRun, MediaObject
from app.modules.media.policy import MediaPlatformPolicy
from app.modules.media.references import MediaReferenceService
from app.modules.media.storage import LocalBlobBackend

JWT_SECRET = "test-jwt-secret-at-least-thirty-two-bytes"


@pytest.fixture()
def lifecycle_env(tmp_path):
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
        media_orphan_grace_seconds=3600,
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
    yield app, factory, backend, headers, root
    engine.dispose()


def _seed_object(factory, backend, *, owner="user-a", content=b"m" * 4096) -> str:
    from app.modules.media.domain import DigestKind, MediaKind
    from app.modules.media.repository import IngestRequest, MediaRepository

    repository = MediaRepository(factory, backend=backend)
    result = repository.ingest(
        IngestRequest(
            owner_id=owner,
            origin_domain="moments",
            kind=MediaKind.IMAGE,
            mime="image/jpeg",
            content=content,
            digest_kind=DigestKind.PLAINTEXT,
            visibility=VisibilityTier.PRIVATE,
        )
    )
    return result.media_id


# --------------------------------------------------------------------------- #
# Test 2 — release one of two references; the object survives
# --------------------------------------------------------------------------- #
def test_two_references_and_releasing_one_keeps_the_object(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    references = MediaReferenceService(factory)

    chat = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.CHAT_MESSAGE,
        business_id="$event-1",
        variant_kind=VariantKind.THUMBNAIL.value,
        permission_scope=VisibilityTier.AUDIENCE,
    )
    moment = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-10",
        variant_kind=VariantKind.ORIGINAL.value,
        permission_scope=VisibilityTier.AUDIENCE,
    )
    assert chat.reference_id != moment.reference_id
    assert references.recount(media_id) == 2

    references.release(
        reference_id=chat.reference_id,
        actor_id="user-a",
        reason=ReleaseReason.MESSAGE_DELETED,
    )
    assert references.recount(media_id) == 1

    with factory() as session:
        media = session.get(MediaObject, media_id)
        blob = session.scalars(select(MediaBlob)).first()
    assert media is not None
    assert media.status == MediaStatus.ACTIVE.value
    assert blob is not None and blob.status != "DELETED"
    remaining = references.list_for_media(media_id)
    assert [view.business_id for view in remaining] == ["moment-10"]


def test_attaching_the_same_business_object_twice_is_idempotent(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    references = MediaReferenceService(factory)
    first = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-11",
    )
    second = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-11",
    )
    assert first.reference_id == second.reference_id
    assert references.recount(media_id) == 1


def test_released_reference_can_be_attached_again(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    references = MediaReferenceService(factory)
    view = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-12",
    )
    references.release(reference_id=view.reference_id, actor_id="user-a")
    again = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-12",
    )
    assert again.state == "active"
    assert references.recount(media_id) == 1


def test_other_user_cannot_reference_or_release_plaintext_media(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend, owner="user-a")
    references = MediaReferenceService(factory)

    from app.core.errors import AppError

    with pytest.raises(AppError) as denied:
        references.attach(
            media_id=media_id,
            actor_id="user-b",
            business_type=BusinessType.MOMENT,
            business_id="moment-13",
        )
    assert denied.value.code == "MEDIA_ACCESS_DENIED"

    view = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-13",
    )
    with pytest.raises(AppError) as release_denied:
        references.release(reference_id=view.reference_id, actor_id="user-b")
    assert release_denied.value.code == "MEDIA_ACCESS_DENIED"
    # The reference is untouched.
    assert references.recount(media_id) == 1


def test_release_for_business_never_touches_another_users_reference(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend, owner="user-a")
    references = MediaReferenceService(factory)
    references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-14",
    )
    released = references.release_for_business(
        business_type=BusinessType.MOMENT,
        business_id="moment-14",
        reason=ReleaseReason.MOMENT_DELETED,
        actor_id="user-b",
    )
    assert released == []
    assert references.recount(media_id) == 1


def test_declared_reference_is_advisory_and_recorded(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    references = MediaReferenceService(factory)
    view = references.attach(
        media_id=media_id,
        actor_id="user-a",
        business_type=BusinessType.CHAT_MESSAGE,
        business_id="$declared-1",
        ref_kind=ReferenceKind.DECLARED,
    )
    assert view.ref_kind == ReferenceKind.DECLARED.value
    # It still counts as an active reference for the collector: a declared reference can
    # keep bytes alive, it just can never be the *only* reason they are deleted.
    assert references.recount(media_id) == 1


# --------------------------------------------------------------------------- #
# Test 7 — GC
# --------------------------------------------------------------------------- #
def test_gc_collects_only_unreferenced_objects_after_grace(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    orphan_id = _seed_object(factory, backend, content=b"orphan" * 700)
    kept_id = _seed_object(factory, backend, content=b"kept" * 800)
    references = MediaReferenceService(factory)
    references.attach(
        media_id=kept_id,
        actor_id="user-a",
        business_type=BusinessType.MOMENT,
        business_id="moment-20",
    )

    policy = MediaPlatformPolicy(orphan_grace_seconds=0)
    collector = MediaGarbageCollector(factory, backend=backend, policy=policy)
    report = collector.run(mode=GcMode.DRY_RUN)

    assert report.dry_run is True
    actions = {decision.media_id: decision for decision in report.decisions}
    assert actions[kept_id].action == "skip"
    assert actions[kept_id].reason == GcSkipReason.HAS_REFERENCES.value
    assert actions[orphan_id].action == "would_collect"
    # Dry run changed nothing.
    with factory() as session:
        assert session.get(MediaObject, orphan_id).status == MediaStatus.ACTIVE.value

    enforced = collector.run(mode=GcMode.ENFORCE)
    assert enforced.collected >= 1
    with factory() as session:
        assert session.get(MediaObject, orphan_id).status == MediaStatus.DELETED.value
        assert session.get(MediaObject, kept_id).status == MediaStatus.ACTIVE.value
        blob = session.scalars(
            select(MediaBlob).where(MediaBlob.object_id == orphan_id)
        ).first()
        assert blob.status == "DELETED"
    assert backend.exists(_blob_key(factory, orphan_id)) is False


def test_gc_respects_the_grace_period(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    policy = MediaPlatformPolicy(orphan_grace_seconds=7 * 24 * 3600)
    collector = MediaGarbageCollector(factory, backend=backend, policy=policy)
    report = collector.run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}
    assert decisions[media_id].reason == GcSkipReason.WITHIN_GRACE.value
    with factory() as session:
        assert session.get(MediaObject, media_id).status == MediaStatus.ACTIVE.value


def test_gc_never_collects_a_pinned_object(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    pin_object(factory, media_id=media_id, seconds=600)
    collector = MediaGarbageCollector(
        factory, backend=backend, policy=MediaPlatformPolicy(orphan_grace_seconds=0)
    )
    report = collector.run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}
    assert decisions[media_id].reason == GcSkipReason.PINNED.value
    with factory() as session:
        assert session.get(MediaObject, media_id).status == MediaStatus.ACTIVE.value


def test_gc_keeps_quarantined_bytes_as_a_tombstone(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    with factory.begin() as session:
        media = session.get(MediaObject, media_id)
        media.quarantined_at = datetime.now(timezone.utc)
        media.quarantine_reason = "moderation"
    collector = MediaGarbageCollector(
        factory, backend=backend, policy=MediaPlatformPolicy(orphan_grace_seconds=0)
    )
    report = collector.run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}
    assert decisions[media_id].reason == GcSkipReason.QUARANTINED.value
    with factory() as session:
        assert session.get(MediaObject, media_id).status != MediaStatus.DELETED.value


def test_gc_resumes_a_stuck_deleting_object(lifecycle_env) -> None:
    """Recovery: a crash between marking and unlinking must not strand the object."""

    _, factory, backend, _, _ = lifecycle_env
    media_id = _seed_object(factory, backend)
    with factory.begin() as session:
        media = session.get(MediaObject, media_id)
        media.status = MediaStatus.DELETING.value
        media.deleting_at = datetime.now(timezone.utc) - timedelta(days=1)
        media.unreferenced_at = datetime.now(timezone.utc) - timedelta(days=1)

    collector = MediaGarbageCollector(
        factory, backend=backend, policy=MediaPlatformPolicy(orphan_grace_seconds=0)
    )
    report = collector.run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}
    assert decisions[media_id].action == "collect"
    assert decisions[media_id].reason == "recover_deleting"
    with factory() as session:
        assert session.get(MediaObject, media_id).status == MediaStatus.DELETED.value


def test_gc_e2ee_domain_keeps_the_retention_floor(lifecycle_env) -> None:
    """E2EE references are unknowable, so the floor protects recent orphans."""

    _, factory, backend, _, _ = lifecycle_env
    from app.modules.media.domain import DigestKind, EnvelopeMode, MediaKind
    from app.modules.media.repository import IngestRequest, MediaRepository

    repository = MediaRepository(factory, backend=backend)
    result = repository.ingest(
        IngestRequest(
            owner_id="user-a",
            origin_domain="chat",
            kind=MediaKind.VIDEO,
            mime="video/mp4",
            content=b"cipher" * 8192,
            digest_kind=DigestKind.CIPHERTEXT,
            envelope_mode=EnvelopeMode.DETERMINISTIC_V1,
        )
    )
    policy = MediaPlatformPolicy(orphan_grace_seconds=0, e2ee_retention_floor_seconds=3600)
    collector = MediaGarbageCollector(factory, backend=backend, policy=policy)
    report = collector.run(mode=GcMode.ENFORCE)
    decisions = {decision.media_id: decision for decision in report.decisions}
    assert decisions[result.media_id].reason == GcSkipReason.WITHIN_GRACE.value


def test_gc_audit_row_has_no_sensitive_fields(lifecycle_env) -> None:
    _, factory, backend, _, _ = lifecycle_env
    _seed_object(factory, backend)
    collector = MediaGarbageCollector(
        factory, backend=backend, policy=MediaPlatformPolicy(orphan_grace_seconds=0)
    )
    collector.run(mode=GcMode.DRY_RUN)
    with factory() as session:
        run = session.scalars(select(MediaGcRun)).first()
    assert run is not None
    serialized = f"{run.decisions}"
    for forbidden in ("media/user", "plaintext_digest", "@", "Bearer"):
        assert forbidden not in serialized
    assert all(set(entry) == {"media_id", "action", "reason"} for entry in run.decisions)


# --------------------------------------------------------------------------- #
# HTTP surface for references and GC
# --------------------------------------------------------------------------- #
@pytest.mark.asyncio
async def test_reference_endpoints_and_gc_endpoint(lifecycle_env) -> None:
    app, factory, backend, headers, _ = lifecycle_env
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://media.local") as client:
        created = await client.post(
            "/api/v1/media/platform/objects",
            params={"kind": "image", "mime": "image/jpeg"},
            headers={**headers["user-a"], "Content-Type": "image/jpeg"},
            content=b"http-ref" * 300,
        )
        assert created.status_code == 201, created.text
        media_id = created.json()["media_id"]

        attached = await client.post(
            f"/api/v1/media/platform/objects/{media_id}/references",
            json={
                "business_type": "moment",
                "business_id": "moment-30",
                "permission_scope": "audience",
            },
            headers=headers["user-a"],
        )
        assert attached.status_code == 201, attached.text
        reference_id = attached.json()["reference_id"]

        listed = await client.get(
            f"/api/v1/media/platform/objects/{media_id}/references",
            headers=headers["user-a"],
        )
        assert listed.status_code == 200
        assert [item["business_id"] for item in listed.json()["items"]] == ["moment-30"]

        # GC in dry-run mode refuses to collect a referenced object.
        gc = await client.post(
            "/api/v1/media/platform/gc", params={"mode": "dry_run"}, headers=headers["user-a"]
        )
        assert gc.status_code == 200, gc.text
        payload = gc.json()
        assert payload["dry_run"] is True
        decisions = {entry["media_id"]: entry for entry in payload["decisions"]}
        assert decisions[media_id]["action"] == "skip"
        assert decisions[media_id]["reason"] == "has_references"

        released = await client.delete(
            f"/api/v1/media/platform/references/{reference_id}",
            params={"reason": "moment_deleted"},
            headers=headers["user-a"],
        )
        assert released.status_code == 200
        assert released.json()["state"] == "released"
        assert released.json()["release_reason"] == "moment_deleted"


@pytest.mark.asyncio
async def test_gc_endpoint_requires_maintenance_in_production_config(lifecycle_env) -> None:
    app, factory, backend, headers, root = lifecycle_env
    from app.integrations.private_storage import LocalPrivateObjectStorage
    from app.main import create_app as build_app

    gated_settings = Settings(
        _env_file=None,
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://unused",
        jwt_secret=JWT_SECRET,
        email_verification_secret="test-email-verification-secret",
        password_reset_secret="test-password-reset-secret",
        media_maintenance_token="gc-token",
        avatar_storage_root=root,
    )
    gated = build_app(
        gated_settings,
        session_factory=factory,
        avatar_storage=LocalPrivateObjectStorage(
            root=root,
            signing_secret="test-media-signing-secret-32-bytes",
            public_base_url="http://mediatest.local",
        ),
    )
    async with AsyncClient(transport=ASGITransport(app=gated), base_url="http://media.local") as client:
        denied = await client.post("/api/v1/media/platform/gc", params={"mode": "dry_run"})
        assert denied.status_code == 403
        allowed = await client.post(
            "/api/v1/media/platform/gc",
            params={"mode": "dry_run"},
            headers={"X-Media-Maintenance-Token": "gc-token"},
        )
        assert allowed.status_code == 200


def _blob_key(factory, media_id: str) -> str:
    with factory() as session:
        blob = session.scalars(
            select(MediaBlob).where(MediaBlob.object_id == media_id)
        ).first()
        return blob.storage_key if blob else ""
