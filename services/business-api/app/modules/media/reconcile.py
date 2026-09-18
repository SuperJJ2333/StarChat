"""Storage/metadata reconciliation (readiness fix for the Data-003 recovery cases).

The readiness audit found two one-directional inconsistency windows with no recovery path:

* **object written, index missing** — ingest writes the file and then commits the blob row; a
  crash (or a failed commit) between the two leaves bytes on disk that no row points at. The
  bytes are invisible forever, unreachable and unreclaimable, and a re-upload cannot reuse
  them because the digest lookup only consults the database.
* **index present, object missing** — the reverse: a row points at a file that is not there,
  so every read answers 503 and the row keeps reserving its digest slot.

``MediaReconciler`` closes both, in the frozen spirit of "metadata is rebuildable, bytes are
the truth" (ADR-002/P3) and "mark before delete" (ADR-006):

* missing file → the blob row is invalidated (``DELETED``), releasing the digest slot so the
  content can be stored again;
* file without a row → the bytes are re-hashed **with the digest kind implied by their
  isolation segment** (``.../media/e2ee/...`` is ciphertext, anything else is plaintext) and a
  blob row is rebuilt, which makes the file discoverable and re-attachable.

It never moves, rewrites or deletes a *valid* file, and it defaults to ``dry_run``.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from sqlalchemy import select

from app.modules.media.domain import (
    BlobStatus,
    DigestKind,
    EnvelopeMode,
    IsolationDomain,
    MediaKind,
    new_blob_id,
    owner_scope_key,
)
from app.core.errors import AppError
from app.modules.media.metrics import media_platform_metrics
from app.modules.media.models import MediaBlob
from app.modules.media.repository import utcnow
from app.modules.media.storage import BlobBackend


@dataclass(frozen=True, slots=True)
class ReconcileReport:
    dry_run: bool
    scanned_blobs: int
    scanned_files: int
    missing_files: tuple[str, ...] = ()
    orphan_files: tuple[str, ...] = ()
    invalidated: int = 0
    rebuilt: int = 0
    errors: tuple[str, ...] = ()

    def as_dict(self) -> dict:
        return {
            "dry_run": self.dry_run,
            "scanned_blobs": self.scanned_blobs,
            "scanned_files": self.scanned_files,
            "missing_files": len(self.missing_files),
            "orphan_files": len(self.orphan_files),
            "invalidated": self.invalidated,
            "rebuilt": self.rebuilt,
            "errors": list(self.errors),
        }


#: Only these prefixes are platform-managed. Legacy ``moments/<actor>/…`` and ``avatars/…``
#: objects are deliberately out of scope: they never had a blob row and are not ours to
#: re-index.
PLATFORM_KEY_PREFIXES = ("media/", "moments/media/")


@dataclass
class _Stats:
    scanned_blobs: int = 0
    scanned_files: int = 0
    missing: list[str] = field(default_factory=list)
    orphan: list[str] = field(default_factory=list)
    invalidated: int = 0
    rebuilt: int = 0
    errors: list[str] = field(default_factory=list)


def _resolve_root(backend: object, explicit: str | None) -> Path:
    """Locate the object directory this reconciler scans.

    Reconcile is the one media component that must read the directory itself: a file without
    a row has no other way to be discovered. ``LocalBlobBackend`` exposes its root publicly,
    while the avatar store the platform is deployed against keeps the same directory behind a
    private ``_root``, so both spellings are accepted instead of assuming one backend class.
    """
    if explicit:
        return Path(explicit).resolve()
    for attribute in ("root", "_root"):
        candidate = getattr(backend, attribute, None)
        if candidate:
            return Path(candidate).resolve()
    raise AppError(
        code="MEDIA_RECONCILE_ROOT_UNKNOWN",
        message="媒体存储根目录未配置",
        status_code=500,
    )


class MediaReconciler:
    def __init__(
        self,
        session_factory,
        *,
        backend: BlobBackend,
        root: str | None = None,
        now_factory=utcnow,
    ) -> None:
        self._session_factory = session_factory
        self._backend = backend
        self._now = now_factory
        self._root = _resolve_root(backend, root)

    # ------------------------------------------------------------------ #
    # Entry point
    # ------------------------------------------------------------------ #
    def run(self, *, dry_run: bool = True, limit: int = 10_000) -> ReconcileReport:
        stats = _Stats()
        now = self._now()
        with self._session_factory() as session:
            blobs = list(
                session.scalars(
                    select(MediaBlob)
                    .where(MediaBlob.status != BlobStatus.DELETED.value)
                    .limit(limit)
                )
            )
        stats.scanned_blobs = len(blobs)

        known_keys: set[str] = set()
        for blob in blobs:
            known_keys.add(blob.storage_key)
            if not self._exists(blob.storage_key):
                stats.missing.append(blob.blob_id)
                if not dry_run:
                    self._invalidate(blob.blob_id, now=now)
                    stats.invalidated += 1

        for key in self._platform_files(limit=limit):
            stats.scanned_files += 1
            if key in known_keys or self._row_exists_for(key):
                continue
            stats.orphan.append(key)
            if not dry_run:
                if self._rebuild(key, now=now):
                    stats.rebuilt += 1
                else:
                    stats.errors.append("rebuild_failed")

        if not dry_run and stats.rebuilt:
            media_platform_metrics.increment("reconcile_rebuilt", stats.rebuilt)
        if not dry_run and stats.invalidated:
            media_platform_metrics.increment("reconcile_invalidated", stats.invalidated)

        return ReconcileReport(
            dry_run=dry_run,
            scanned_blobs=stats.scanned_blobs,
            scanned_files=stats.scanned_files,
            missing_files=tuple(stats.missing),
            orphan_files=tuple(stats.orphan),
            invalidated=stats.invalidated,
            rebuilt=stats.rebuilt,
            errors=tuple(stats.errors),
        )

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    def _exists(self, key: str) -> bool:
        probe = getattr(self._backend, "exists", None)
        if callable(probe):
            return bool(probe(key))
        # A backend that predates the media platform exposes no existence probe; for a
        # filesystem-backed store the object directory is the source of truth.
        return self._path(key).is_file()

    def _path(self, key: str) -> Path:
        if not key or key.startswith("/") or ".." in Path(key).parts:
            raise AppError(
                code="MEDIA_STORAGE_KEY_INVALID",
                message="媒体存储引用无效",
                status_code=500,
            )
        candidate = (self._root / key).resolve()
        if candidate == self._root or self._root not in candidate.parents:
            raise AppError(
                code="MEDIA_STORAGE_KEY_INVALID",
                message="媒体存储引用无效",
                status_code=500,
            )
        return candidate

    def _platform_files(self, *, limit: int) -> list[str]:
        found: list[str] = []
        for prefix in PLATFORM_KEY_PREFIXES:
            base = self._root / prefix
            if not base.is_dir():
                continue
            for path in sorted(base.rglob("*")):
                if len(found) >= limit:
                    return found
                if not path.is_file() or path.name.endswith(".tmp"):
                    continue
                found.append(str(path.relative_to(self._root)).replace("\\", "/"))
        return found

    def _row_exists_for(self, key: str) -> bool:
        with self._session_factory() as session:
            return (
                session.scalars(
                    select(MediaBlob.blob_id).where(MediaBlob.storage_key == key).limit(1)
                ).first()
                is not None
            )

    def _invalidate(self, blob_id: str, *, now: datetime) -> None:
        with self._session_factory.begin() as session:
            blob = session.get(MediaBlob, blob_id)
            if blob is None or blob.status == BlobStatus.DELETED.value:
                return
            blob.status = BlobStatus.DELETED.value
            blob.deleted_at = now
            # There is nothing to unlink, so this is the whole repair: the digest slot is
            # released and a later upload of the same content can store it again.

    def _rebuild(self, key: str, *, now: datetime) -> bool:
        try:
            path = self._path(key)
            content = path.read_bytes()
        except OSError:
            return False

        digest_kind = self._digest_kind_for(key)
        if digest_kind is None:
            return False
        from app.modules.media.domain import ciphertext_digest, plaintext_digest

        digest = (
            ciphertext_digest(content)
            if digest_kind is DigestKind.CIPHERTEXT
            else plaintext_digest(content)
        )
        segment = self._isolation_segment(key)
        if segment is None:
            return False
        domain = {
            "user": IsolationDomain.USER,
            "e2ee": IsolationDomain.E2EE,
            "public": IsolationDomain.SYSTEM_PUBLIC,
        }[segment]
        # The owner id cannot be recovered from a hashed scope, so the rebuilt blob is
        # recorded as unattached (``object_id is None``) and with an unreachable scope: it is
        # discoverable and re-attachable, and can never be mistaken for someone's live media.
        scope_key = (
            owner_scope_key(domain, "recovered")
            if domain is IsolationDomain.USER
            else owner_scope_key(domain, "")
        )
        mime = _mime_for_suffix(path.suffix)

        with self._session_factory.begin() as session:
            existing = session.scalars(
                select(MediaBlob).where(MediaBlob.storage_key == key).limit(1)
            ).first()
            if existing is not None:
                # A tombstoned row for the same key: revive it rather than collide.
                existing.status = BlobStatus.VERIFIED.value
                existing.deleted_at = None
                existing.content_digest = digest.value
                existing.digest_kind = digest.kind.value
                existing.size = len(content)
                existing.verified_at = now
                return True
            session.add(
                MediaBlob(
                    blob_id=new_blob_id(),
                    object_id=None,
                    owner_id="recovered",
                    owner_scope=scope_key,
                    isolation_domain=domain.value,
                    digest_kind=digest.kind.value,
                    digest_version=digest.version,
                    content_digest=digest.value,
                    size=len(content),
                    mime=mime,
                    storage_backend="local_private",
                    storage_key=key,
                    envelope_mode=EnvelopeMode.NONE.value,
                    envelope_version=1,
                    dedup_eligible=False,
                    status=BlobStatus.VERIFIED.value,
                    created_at=now,
                    verified_at=now,
                )
            )
        return True

    @staticmethod
    def _isolation_segment(key: str) -> str | None:
        parts = key.split("/")
        for index in range(len(parts) - 1):
            if parts[index] == "media" and parts[index + 1] in ("user", "e2ee", "public"):
                return parts[index + 1]
        return None

    def _digest_kind_for(self, key: str) -> DigestKind | None:
        segment = self._isolation_segment(key)
        if segment == "e2ee":
            return DigestKind.CIPHERTEXT
        if segment in ("user", "public"):
            return DigestKind.PLAINTEXT
        return None


_SUFFIX_MIME = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".m4a": "audio/mp4",
    ".aac": "audio/aac",
    ".mp3": "audio/mpeg",
    ".pdf": "application/pdf",
    ".zip": "application/zip",
    ".txt": "text/plain",
    ".bin": "application/octet-stream",
}


def _mime_for_suffix(suffix: str) -> str:
    return _SUFFIX_MIME.get(suffix.casefold(), "application/octet-stream")


def media_kind_for_mime(mime: str) -> MediaKind:
    if mime.startswith("image/gif"):
        return MediaKind.GIF
    if mime.startswith("image/"):
        return MediaKind.IMAGE
    if mime.startswith("video/"):
        return MediaKind.VIDEO
    if mime.startswith("audio/"):
        return MediaKind.AUDIO
    return MediaKind.FILE
