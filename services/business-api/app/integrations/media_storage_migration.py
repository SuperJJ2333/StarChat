"""Bounded copy candidate. Metadata stays authoritative; audit sink is server-private.

Run only after all writers/GC use compatible two-store reads and deletes. PostgreSQL
row locks hold each eligibility check through copy/readback. SQLite unit tests cannot
prove that concurrency gate. No local bytes or database rows are mutated here.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib

from sqlalchemy import select

from app.core.errors import AppError
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import AvatarUpload, User
from app.modules.media.domain import BlobStatus, DigestKind, MediaStatus
from app.modules.media.models import MediaBlob, MediaObject
from app.modules.media.storage import key_belongs_to_domain
from app.modules.moments.media import MomentMediaUpload
from app.modules.moments.models import MomentsPreference


@dataclass
class MigrationReport:
    kind: str
    dry_run: bool
    scanned: int = 0
    skipped: int = 0
    would_copy: int = 0
    copied: int = 0
    already_present: int = 0
    bytes_verified: int = 0
    next_cursor: str | None = None

    def as_dict(self) -> dict:
        # IDs/counters only. Object keys/digests go exclusively to the private sink.
        return asdict(self)


def _mismatch() -> AppError:
    return AppError(code='MEDIA_MIGRATION_CONTENT_MISMATCH',
        message='媒体迁移字节校验失败', status_code=503)


class MediaStorageMigration:
    def __init__(self, session_factory, *, source, target, audit_sink=None,
                 compatible_reads_enabled: bool = False,
                 max_object_bytes: int = 64 * 1024 * 1024) -> None:
        self._factory = session_factory
        self._source, self._target = source, target
        self._audit = audit_sink
        self._compatible = compatible_reads_enabled
        if not 1 <= max_object_bytes <= 512 * 1024 * 1024:
            raise ValueError('migration object bound invalid')
        self._max_bytes = max_object_bytes

    def run(self, *, kind: str, dry_run: bool = True, limit: int = 100,
            cursor: str | None = None) -> MigrationReport:
        models = {'platform': (MediaBlob, MediaBlob.blob_id),
                  'avatars': (AvatarUpload, AvatarUpload.id),
                  'moments': (MomentMediaUpload, MomentMediaUpload.id)}
        if kind not in models or type(limit) is not int or not 1 <= limit <= 200:
            raise ValueError('migration kind/page size invalid')
        if cursor is not None and (not isinstance(cursor, str) or len(cursor) > 128):
            raise ValueError('migration cursor invalid')
        if not dry_run and (not self._compatible or not callable(self._audit)):
            raise ValueError('enforce requires compatible live readers/GC and a private audit sink')
        model, identifier = models[kind]
        query = select(identifier).order_by(identifier).limit(limit + 1)
        if cursor is not None:
            query = query.where(identifier > cursor)
        with self._factory() as session:
            ids = list(session.scalars(query))
        report = MigrationReport(kind, dry_run)
        for identity in ids[:limit]:
            with self._factory.begin() as session:
                descriptor = self._descriptor(session, kind, identity)
                report.scanned += 1
                if descriptor is None:
                    report.skipped += 1
                    continue
                key, size, digest = descriptor
                self._copy(key, size, digest, report=report, identity=identity)
        if len(ids) > limit:
            report.next_cursor = ids[limit - 1]
        return report

    def _platform(self, session, blob_id: str):
        # Match GC's parent-then-blob locking order. Re-read blob after acquiring both.
        parent_id = session.scalar(select(MediaBlob.object_id).where(MediaBlob.blob_id == blob_id))
        if parent_id is None:
            return None
        media = session.scalar(select(MediaObject).where(MediaObject.media_id == parent_id).with_for_update())
        blob = session.scalar(select(MediaBlob).where(MediaBlob.blob_id == blob_id).with_for_update())
        if (media is None or blob is None or blob.object_id != parent_id
                or media.status not in (MediaStatus.ACTIVE.value, MediaStatus.ORPHAN.value)
                or media.deleted_at is not None or media.deleting_at is not None
                or media.quarantined_at is not None or blob.status != BlobStatus.VERIFIED.value
                or blob.retiring_at is not None or blob.deleted_at is not None):
            return None
        try:
            valid_domain = key_belongs_to_domain(blob.storage_key,
                digest_kind=DigestKind(blob.digest_kind), owner_scope=blob.owner_scope)
        except (ValueError, AppError):
            raise _mismatch() from None
        if not valid_domain:
            raise _mismatch()
        return blob.storage_key, blob.size, blob.content_digest

    def _descriptor(self, session, kind: str, identity: str):
        if kind == 'platform':
            return self._platform(session, identity)
        if kind == 'avatars':
            # Avatar completion locks upload before user; preserve that ordering.
            upload = session.scalar(select(AvatarUpload).where(AvatarUpload.id == identity).with_for_update())
            if upload is None or upload.status != 'COMPLETED' or upload.cancelled_at is not None:
                return None
            user = session.scalar(select(User).where(User.id == upload.owner_id).with_for_update())
            if user is None or user.status != AccountStatus.ACTIVE or user.avatar_object_key != upload.object_key:
                return None
            return upload.object_key, upload.byte_size, upload.content_hash
        upload = session.scalar(select(MomentMediaUpload).where(MomentMediaUpload.id == identity).with_for_update())
        if upload is None or upload.status != 'COMPLETED':
            return None
        user = session.scalar(select(User).where(User.id == upload.owner_id))
        if user is None or user.status != AccountStatus.ACTIVE:
            return None
        # A platform-managed Moments key must never bypass the platform tombstone.
        blob_id = session.scalar(select(MediaBlob.blob_id).where(MediaBlob.storage_key == upload.object_key))
        if blob_id is not None:
            return self._platform(session, blob_id)
        if upload.purpose == 'MOMENT_COVER':
            preference = session.scalar(select(MomentsPreference)
                .where(MomentsPreference.user_id == upload.owner_id).with_for_update())
            if preference is None or preference.cover_object_key != upload.object_key:
                return None
        # Completed upload rows remain the existing owner capability authority,
        # including draft/unpublished media. This does not revive a deleted post.
        return upload.object_key, upload.byte_size, None

    def _copy(self, key: str, expected_size: int, expected_digest: str | None,
              *, report: MigrationReport, identity: str) -> None:
        if type(expected_size) is not int or not 0 <= expected_size <= self._max_bytes:
            raise _mismatch()
        content = self._source.get_bounded(key, max_bytes=self._max_bytes)
        digest = hashlib.sha256(content).hexdigest()
        if len(content) != expected_size or expected_digest is not None and expected_digest != digest:
            raise _mismatch()
        if report.dry_run:
            report.would_copy += 1
            report.bytes_verified += len(content)
            return
        present = self._target.exists(key)
        if present:
            previous = self._target.get(key)
            if len(previous) != len(content) or hashlib.sha256(previous).hexdigest() != digest:
                raise _mismatch()
        else:
            self._target.put(key, content)
            restored = self._target.get(key)
            if len(restored) != len(content) or hashlib.sha256(restored).hexdigest() != digest:
                raise _mismatch()
        self._audit({'kind': report.kind, 'identity': identity, 'storage_key': key,
            'sha256': digest, 'size': len(content), 'already_present': present})
        report.already_present += int(present)
        report.copied += int(not present)
        report.bytes_verified += len(content)

    def inventory_derived(self, *, limit: int = 1000, cursor: str | None = None):
        """Inventory only. No row authority exists for the old compression renditions."""
        return self._source.list_page(prefix='media/renders/', limit=limit, cursor=cursor)
