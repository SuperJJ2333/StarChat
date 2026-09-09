"""Shared MXC identity with independent uploader references (ADR-0060).

Installed as synapse.media.chatflow_media_dedup by the pinned image build.
SQL functions intentionally use only the transaction interface so they are
exercised on real SQLite in addition to the Synapse integration suite.
"""
import hashlib
from contextlib import asynccontextmanager
from functools import wraps
import logging
import os
import secrets

logger = logging.getLogger(__name__)
LOCK_NAME = "chatflow_media_lifecycle_v1"
LOCK_KEY = "local"


def enabled():
    return os.environ.get("CHATFLOW_MEDIA_DEDUP", "false").lower() in ("1", "true", "yes")


@asynccontextmanager
async def lock(hs):
    # Serialize local waiters before the distributed lock. Synapse's distributed
    # wakeup precedes SQL unlock and contending local waiters can miss it, then
    # enter exponential polling backoff. Cross-process exclusion stays intact.
    from synapse.util.async_helpers import Linearizer
    if not hasattr(hs, "_chatflow_media_linearizer"):
        hs._chatflow_media_linearizer = Linearizer(name="chatflow_media_lifecycle")
    async with hs._chatflow_media_linearizer.queue(LOCK_KEY):
        async with hs.get_worker_locks_handler().acquire_lock(LOCK_NAME, LOCK_KEY):
            yield


def media_lifecycle(method):
    @wraps(method)
    async def wrapped(self, *args, **kwargs):
        async with lock(self.hs):
            return await method(self, *args, **kwargs)
    return wrapped


def content_digest(content, content_length):
    position = content.tell()
    digest = hashlib.sha256()
    length = 0
    for chunk in iter(lambda: content.read(1024 * 1024), b""):
        digest.update(chunk)
        length += len(chunk)
    content.seek(position)
    if length != content_length:
        from synapse.api.errors import SynapseError
        raise SynapseError(400, "Media length mismatch")
    return digest.hexdigest()


def lookup(txn, digest):
    txn.execute("SELECT media_id FROM chatflow_media_blobs WHERE digest = ? AND retiring=0", (digest,))
    row = txn.fetchone()
    return row[0] if row else None


def retiring(txn, digest):
    txn.execute("SELECT media_id FROM chatflow_media_blobs WHERE digest=? AND retiring=1", (digest,))
    row = txn.fetchone()
    return row[0] if row else None


def pending(txn, digest):
    txn.execute("SELECT media_id FROM chatflow_media_pending WHERE digest=?", (digest,))
    row = txn.fetchone()
    return row[0] if row else None


def reserve(txn, digest, media_id):
    txn.execute("INSERT INTO chatflow_media_pending (digest, media_id) VALUES (?, ?)", (digest, media_id))


def retire(txn, media_ids):
    for media_id in media_ids:
        if active(txn, media_id):
            raise ValueError("cannot retire referenced media")
        txn.execute("UPDATE chatflow_media_blobs SET retiring=1 WHERE media_id=?", (media_id,))


def blocked(txn, digest):
    # Do not use get_is_hash_quarantined's background-index-not-ready bypass.
    txn.execute("""SELECT 1 FROM local_media_repository
        WHERE sha256 = ? AND quarantined_by IS NOT NULL
        UNION ALL SELECT 1 FROM remote_media_cache
        WHERE sha256 = ? AND quarantined_by IS NOT NULL LIMIT 1""", (digest, digest))
    return txn.fetchone() is not None


def publish(txn, digest, media_id, user_id, now, media_type, upload_name, length):
    txn.execute("""INSERT INTO chatflow_media_blobs (digest, media_id)
        VALUES (?, ?) ON CONFLICT (digest) DO NOTHING""", (digest, media_id))
    if lookup(txn, digest) != media_id:
        raise ValueError("canonical media conflict")
    txn.execute("""INSERT INTO chatflow_media_references
        (media_id, user_id, created_ts, last_uploaded_ts, deleted_ts,
         media_type, upload_name, media_length)
        VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
        ON CONFLICT (media_id, user_id) DO UPDATE SET
        last_uploaded_ts=excluded.last_uploaded_ts, deleted_ts=NULL,
        media_type=excluded.media_type, upload_name=excluded.upload_name,
        media_length=excluded.media_length""",
        (media_id, user_id, now, now, media_type, upload_name, length))
    txn.execute("UPDATE chatflow_media_blobs SET unreferenced_ts=NULL WHERE media_id=?", (media_id,))
    txn.execute("DELETE FROM chatflow_media_pending WHERE media_id=?", (media_id,))


def active(txn, media_id):
    txn.execute("SELECT 1 FROM chatflow_media_references WHERE media_id=? AND deleted_ts IS NULL LIMIT 1", (media_id,))
    return txn.fetchone() is not None


def logical_delete(txn, media_ids, user_id, now):
    deleted = []
    for media_id in media_ids:
        sql = "UPDATE chatflow_media_references SET deleted_ts=? WHERE media_id=? AND deleted_ts IS NULL"
        args = [now, media_id]
        if user_id is not None:
            sql += " AND user_id=?"
            args.append(user_id)
        txn.execute(sql, args)
        if txn.rowcount:
            deleted.append(media_id)
        if not active(txn, media_id):
            txn.execute("""UPDATE chatflow_media_blobs SET unreferenced_ts=?
                WHERE media_id=? AND unreferenced_ts IS NULL""", (now, media_id))
    return deleted


def mapped(txn, media_id):
    txn.execute("SELECT 1 FROM chatflow_media_blobs WHERE media_id=?", (media_id,))
    return txn.fetchone() is not None


def collectible(txn, media_id, now, grace):
    txn.execute("""SELECT b.unreferenced_ts, m.quarantined_by
        FROM chatflow_media_blobs b LEFT JOIN local_media_repository m
        ON m.media_id=b.media_id WHERE b.media_id=?""", (media_id,))
    row = txn.fetchone()
    if row is None:
        return True  # unchanged legacy lifecycle
    dead_at, quarantined_by = row
    # Keep quarantined rows as digest tombstones until explicitly unquarantined.
    return (dead_at is not None and dead_at + grace <= now
            and quarantined_by is None and not active(txn, media_id))


def forget(txn, media_ids):
    for media_id in media_ids:
        txn.execute("DELETE FROM chatflow_media_references WHERE media_id=?", (media_id,))
        txn.execute("DELETE FROM chatflow_media_blobs WHERE media_id=?", (media_id,))
        txn.execute("DELETE FROM chatflow_media_pending WHERE media_id=?", (media_id,))


class ContentAddressedMedia:
    def __init__(self, repository):
        self.repo = repository

    async def transaction(self, function, *args):
        return await self.repo.store.db_pool.runInteraction(
            "chatflow_media_" + function.__name__, function, *args)

    async def create(self, media_type, upload_name, content, content_length, auth_user):
        from synapse.api.errors import SynapseError
        from matrix_common.types.mxc_uri import MXCUri

        digest = content_digest(content, content_length)
        async with lock(self.repo.hs):
            if await self.transaction(blocked, digest):
                raise SynapseError(403, "Media is quarantined")
            abandoned = await self.transaction(pending, digest)
            if abandoned is not None:
                removed, _ = await self.repo._chatflow_remove_local_media_original([abandoned])
                if abandoned not in removed:
                    raise SynapseError(503, "Unpublished media needs storage repair")
                await self.transaction(forget, removed)
            if enabled():
                old = await self.transaction(retiring, digest)
                if old is not None:
                    # Complete a crashed collection before publishing this digest again.
                    removed, _ = await self.repo._chatflow_remove_local_media_original([old])
                    if old not in removed:
                        raise SynapseError(503, "Media collection needs storage repair")
                    await self.transaction(forget, removed)
            canonical = await self.transaction(lookup, digest) if enabled() else None
            if canonical is not None:
                metadata = await self.repo.store.get_local_media(canonical)
                if metadata is None:
                    if await self.transaction(active, canonical):
                        raise SynapseError(503, "Media needs storage repair")
                    # Recovery after physical deletion succeeded but mapping cleanup failed.
                    await self.transaction(forget, [canonical])
                    canonical = None
                else:
                    # Do not return an ID whose backing file disappeared. Storage
                    # providers may restore it; otherwise fail without activating a ref.
                    from synapse.media._base import FileInfo
                    try:
                        await self.repo.media_storage.ensure_media_is_in_local_cache(
                            FileInfo(server_name=None, file_id=canonical))
                    except Exception as exc:
                        raise SynapseError(503, "Media needs storage repair") from exc
            reused = canonical is not None
            if not enabled():
                return await self.repo._chatflow_create_content_original(
                    media_type, upload_name, content, content_length, auth_user)
            if not reused:
                canonical = secrets.token_hex(12)
                # Reserve a recoverable identity before the first filesystem write.
                await self.transaction(reserve, digest, canonical)
            try:
                if not reused:
                    await self.repo._chatflow_create_content_original(
                        media_type, upload_name, content, content_length, auth_user,
                        _chatflow_media_id=canonical)
                await self.transaction(publish, digest, canonical, auth_user.to_string(),
                                       self.repo.clock.time_msec(), media_type, upload_name, content_length)
            except Exception:
                if not reused:
                    # Check an uncertain commit before compensation: never unlink
                    # an ID whose publication actually committed successfully.
                    try:
                        if await self.transaction(lookup, digest) != canonical:
                            removed, _ = await self.repo._chatflow_remove_local_media_original([canonical])
                            if canonical in removed:
                                await self.transaction(forget, removed)
                            else:
                                logger.error("Media publication compensation pending storage recovery")
                    except Exception:
                        logger.error("Media publication compensation requires recovery")
                raise
            # No byte digest, filename, credentials, or message content in logs.
            logger.info("ChatFlow media upload deduplicated=%s", reused)
            return MXCUri(self.repo.server_name, canonical)

    async def update(self, media_id, media_type, upload_name, content, content_length, auth_user):
        # A pre-reserved MXC cannot be changed to another ID. Preserve its legacy
        # identity, but enforce the same quarantine boundary on this upload API.
        from synapse.api.errors import SynapseError
        digest = content_digest(content, content_length)
        async with lock(self.repo.hs):
            if await self.transaction(blocked, digest):
                raise SynapseError(403, "Media is quarantined")
            return await self.repo._chatflow_update_content_original(
                media_id, media_type, upload_name, content, content_length, auth_user)

    async def delete(self, media_ids, user_id=None):
        async with lock(self.repo.hs):
            shared, legacy = [], []
            for media_id in media_ids:
                if await self.transaction(mapped, media_id):
                    shared.append(media_id)
                else:
                    # The user route must not delete an unrelated legacy upload.
                    media = await self.repo.store.get_local_media(media_id)
                    if media and (user_id is None or media.user_id == user_id):
                        legacy.append(media_id)
            deleted = await self.transaction(logical_delete, shared, user_id,
                                             self.repo.clock.time_msec())
            removed, _ = await self.repo._chatflow_remove_local_media_original(legacy)
            result = deleted + removed
            return result, len(result)

    async def purge(self, media_ids):
        grace = max(0, int(os.environ.get("CHATFLOW_MEDIA_RETENTION_MS", "604800000")))
        async with lock(self.repo.hs):
            eligible = []
            now = self.repo.clock.time_msec()
            for media_id in media_ids:
                if await self.transaction(collectible, media_id, now, grace):
                    eligible.append(media_id)
            # Persist exclusion from lookup before unlink; retain this recovery
            # record across storage failures and process restarts.
            await self.transaction(retire, eligible)
            removed, count = await self.repo._chatflow_remove_local_media_original(eligible)
            await self.transaction(forget, removed)
            return removed, count
