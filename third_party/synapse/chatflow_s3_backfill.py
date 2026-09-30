"""Bounded local-media S3 backfill in a real, listener-free Synapse worker.

This copies ciphertext only. DB/reference lifecycle and its existing distributed
lock authorize each identity; S3 never supplies authorization. Local bytes stay.
The admission deadline never cancels an in-flight PUT while holding that lock.
Run inside the pinned derivative, with a maintenance-only worker overlay and a
private checkpoint directory mounted separately from the read-only media cache.
"""
import argparse
from contextlib import asynccontextmanager
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time


class QuarantinedDigest(RuntimeError):
    pass


class Limits:
    def __init__(self, objects=20, bytes=32 * 1024 * 1024, seconds=30, page_size=20,
                 object_bytes=8 * 1024 * 1024):
        for value, maximum in ((objects, 1000), (bytes, 1024 * 1024 * 1024),
                               (seconds, 300), (page_size, 100), (object_bytes, 150 * 1024 * 1024)):
            if type(value) is not int or not 1 <= value <= maximum:
                raise ValueError("Invalid bounded backfill limits")
        self.objects, self.bytes, self.seconds = objects, bytes, seconds
        self.page_size, self.object_bytes = page_size, object_bytes


def candidate_page(txn, cursor, upper, count):
    txn.execute("SELECT media_id FROM local_media_repository WHERE media_id>? AND media_id<=? ORDER BY media_id LIMIT ?",
                (cursor, upper, count))
    return [row[0] for row in txn.fetchall()]


def authoritative_media(txn, media_id):
    txn.execute("""SELECT m.media_length,m.url_cache,m.quarantined_by,m.sha256,b.digest,b.retiring,
      EXISTS(SELECT 1 FROM chatflow_media_references r WHERE r.media_id=m.media_id AND r.deleted_ts IS NULL),
      EXISTS(SELECT 1 FROM chatflow_media_pending p WHERE p.media_id=m.media_id)
      FROM local_media_repository m LEFT JOIN chatflow_media_blobs b ON b.media_id=m.media_id WHERE m.media_id=?""", (media_id,))
    row = txn.fetchone()
    if row is None:
        return {"skip": "missing"}
    length, url, quarantine, sha, digest, retiring, active, pending = row
    reason = ("quarantined" if quarantine is not None else "retiring" if retiring else "pending" if pending else
              "url_cache" if url else "incomplete" if type(length) is not int or length < 0 else
              "unreferenced" if digest is not None and not active else None)
    if sha and digest and sha != digest:
        raise RuntimeError("Backfill authoritative digest conflict")
    return {"skip": reason, "length": length, "digest": digest or sha}


def thumbnail_rows(txn, media_id):
    txn.execute("""SELECT thumbnail_width,thumbnail_height,thumbnail_type,thumbnail_method,thumbnail_length
      FROM local_media_repository_thumbnails WHERE media_id=?
      ORDER BY thumbnail_width,thumbnail_height,thumbnail_type,thumbnail_method LIMIT 101""", (media_id,))
    rows = txn.fetchall()
    if len(rows) > 100:
        raise RuntimeError("Backfill thumbnail count exceeds bound")
    return rows


def hash_stream(source, expected):
    digest = hashlib.sha256()
    received = 0
    while True:
        chunk = source.read(1024 * 1024)
        if not chunk:
            break
        received += len(chunk)
        if received > expected:
            raise RuntimeError("Backfill ciphertext length mismatch")
        digest.update(chunk)
    if received != expected:
        raise RuntimeError("Backfill ciphertext length mismatch")
    return digest.hexdigest()


def hash_local(cache, path, expected, maximum):
    file = (cache / path).resolve()
    if not file.is_relative_to(cache) or type(expected) is not int or not 0 <= expected <= maximum:
        raise RuntimeError("Backfill local object outside bound")
    with file.open("rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size != expected:
            raise RuntimeError("Backfill local ciphertext length mismatch")
        digest = hash_stream(source, expected)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
            raise RuntimeError("Backfill local object changed")
        return digest


async def run_io(hs, function, *args):
    from synapse.logging.context import defer_to_thread
    return await defer_to_thread(hs.get_reactor(), function, *args)


async def remote_hash(runner, path, info, expected):
    if type(expected) is not int or not 0 <= expected <= runner.backend.max_object_bytes:
        raise RuntimeError("Backfill remote object outside bound")
    responder = await runner.provider.fetch(path, info)
    if responder is None:
        return None
    # Upstream Responder.__enter__ returns None; FileResponder owns open_file
    # and its public context manager closes it on both success and failure.
    with responder:
        return await run_io(runner.hs, hash_stream, responder.open_file, expected)


async def copy_object(runner, path, info, length, expected_digest):
    backend = runner.backend
    try:
        digest = await run_io(runner.hs, hash_local, backend.cache_directory, path, length, backend.max_object_bytes)
    except FileNotFoundError:
        # Historical S3 reads need not repopulate the local cache. Missing local
        # bytes authorize no PUT; an existing object is verifiable only against
        # an authoritative DB checksum and length, while the lifecycle is locked.
        if expected_digest is None:
            raise RuntimeError("Backfill missing local authoritative ciphertext") from None
        existing = await remote_hash(runner, path, info, length)
        if existing != expected_digest:
            raise RuntimeError("Backfill missing local ciphertext verification failed") from None
        return "verified"
    if expected_digest is not None and digest != expected_digest:
        raise RuntimeError("Backfill authoritative ciphertext digest mismatch")
    if expected_digest is None and getattr(info, "thumbnail", None) is None and await runner.digest_blocked(digest):
        raise QuarantinedDigest("Backfill ciphertext digest is quarantined")
    existing = await remote_hash(runner, path, info, length)
    if existing is not None:
        if existing != digest:
            raise RuntimeError("Backfill remote ciphertext collision")
        return "verified"
    await runner.provider.store_file(path, info)
    copied = await remote_hash(runner, path, info, length)
    if copied != digest:
        raise RuntimeError("Backfill remote verification failed")
    # Detect a concurrently changed source without declaring migration success.
    after = await run_io(runner.hs, hash_local, backend.cache_directory, path, length, backend.max_object_bytes)
    if after != digest:
        raise RuntimeError("Backfill local ciphertext changed")
    return "copied"


class Checkpoint:
    def __init__(self, path, target):
        self.path = Path(path).absolute()
        self.target = target
        if self.path.is_symlink() or self.path.parent.is_symlink():
            raise ValueError("Backfill checkpoint must not be symbolic")
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._private(self.path.parent, directory=True)
        if self.path.exists():
            self._private(self.path)

    @staticmethod
    def _private(path, directory=False):
        value = path.stat()
        if hasattr(os, "geteuid") and (value.st_uid != os.geteuid() or value.st_mode & 0o777 != (0o700 if directory else 0o600)):
            raise ValueError("Backfill checkpoint permissions must be private")
        if (directory and not stat.S_ISDIR(value.st_mode)) or (not directory and not stat.S_ISREG(value.st_mode)):
            raise ValueError("Backfill checkpoint type is invalid")

    def load(self):
        if not self.path.exists():
            return None
        self._private(self.path)
        if self.path.stat().st_size > 4096:
            raise ValueError("Backfill checkpoint exceeds input bound")
        value = json.loads(self.path.read_text(encoding="utf8"))
        if value.get("version") != 1 or value.get("target") != self.target:
            raise ValueError("Backfill checkpoint target mismatch")
        if any(not isinstance(value.get(key), str) or len(value[key]) > 255 for key in ("cursor", "upper")):
            raise ValueError("Backfill checkpoint cursor invalid")
        return value

    def save(self, value):
        if self.path.is_symlink():
            raise ValueError("Backfill checkpoint must not be symbolic")
        fd, name = tempfile.mkstemp(dir=self.path.parent)
        temp = Path(name)
        try:
            with os.fdopen(fd, "w", encoding="utf8") as temporary:
                os.chmod(temp, 0o600)
                json.dump(value, temporary)
                temporary.flush()
                os.fsync(temporary.fileno())
            os.replace(temp, self.path)
            if hasattr(os, "O_DIRECTORY"):
                directory = os.open(self.path.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
        finally:
            temp.unlink(missing_ok=True)

    def audit(self, value):
        path = self.path.with_suffix(self.path.suffix + ".audit.jsonl")
        if path.is_symlink():
            raise ValueError("Backfill audit must not be symbolic")
        if path.exists():
            self._private(path)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w", encoding="utf8") as output:
            encoded = json.dumps(value) + "\n"
            if os.fstat(output.fileno()).st_size + len(encoded.encode("utf8")) > 16 * 1024 * 1024:
                raise ValueError("Backfill audit exceeds disk bound")
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())


@asynccontextmanager
async def bounded_lifecycle_lock(hs, deadline):
    from synapse.media.chatflow_media_dedup import lock
    from twisted.internet.defer import ensureDeferred
    from synapse.util.async_helpers import timeout_deferred
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise RuntimeError("Backfill admission deadline reached")
    context = lock(hs)
    await timeout_deferred(ensureDeferred(context.__aenter__()), remaining, hs.get_reactor())
    try:
        yield
    finally:
        await context.__aexit__(None, None, None)


class BackfillRunner:
    def __init__(self, hs, checkpoint, limits):
        from synapse.media.chatflow_s3_storage import ChatFlowS3StorageProvider
        self.hs, self.limits = hs, limits
        self.repo = hs.get_media_repository()
        wrappers = self.repo.media_storage.storage_providers
        if len(wrappers) != 1 or type(wrappers[0].backend) is not ChatFlowS3StorageProvider:
            raise ValueError("Backfill requires the lifecycle-aware S3 provider")
        self.provider, self.backend = wrappers[0], wrappers[0].backend
        if not self.backend.write_enabled:
            raise ValueError("Backfill requires enabled synchronous S3 writes")
        self.backend.max_object_bytes = min(self.backend.max_object_bytes, limits.object_bytes)
        target = hashlib.sha256(json.dumps(["Synapse/1.132.0", hs.hostname, self.backend.bucket, self.backend.prefix, self.backend.client.meta.region_name, self.backend.client.meta.endpoint_url], separators=(",", ":")).encode()).hexdigest()
        self.checkpoint = Checkpoint(checkpoint, target)
        self.summary = {"copied": 0, "verified": 0, "objects": 0, "bytes": 0, "skipped": {}, "scan_completed": False}

    async def transaction(self, function, *args):
        def bounded(txn):
            # PostgreSQL-local settings expire at transaction end and protect
            # read-only eligibility queries from unrelated concurrent DDL/locks.
            txn.execute("SET LOCAL lock_timeout='1000ms'")
            txn.execute("SET LOCAL statement_timeout='5000ms'")
            return function(txn, *args)
        return await self.repo.store.db_pool.runInteraction("chatflow_s3_backfill_" + function.__name__, bounded)

    async def digest_blocked(self, digest):
        from synapse.media.chatflow_media_dedup import blocked
        return await self.transaction(blocked, digest)

    async def run(self):
        from synapse.media._base import FileInfo, ThumbnailInfo
        from synapse.media.chatflow_media_dedup import blocked
        started = time.monotonic()
        deadline = started + self.limits.seconds
        state = self.checkpoint.load()
        if state is None:
            def upper(txn):
                txn.execute("SELECT COALESCE(MAX(media_id),'') FROM local_media_repository")
                return txn.fetchone()[0]
            state = {"version": 1, "target": self.checkpoint.target, "cursor": "", "upper": await self.transaction(upper)}
            self.checkpoint.save(state)
        examined = 0
        while examined < 1000 and time.monotonic() < deadline:
            ids = await self.transaction(candidate_page, state["cursor"], state["upper"], self.limits.page_size)
            if not ids:
                self.summary["scan_completed"] = True
                break
            for media_id in ids:
                if examined >= 1000 or time.monotonic() >= deadline:
                    break
                async with bounded_lifecycle_lock(self.hs, deadline):
                    metadata = await self.transaction(authoritative_media, media_id)
                    reason = metadata["skip"]
                    if not reason and metadata["digest"] and await self.transaction(blocked, metadata["digest"]):
                        reason = "quarantined_digest"
                    if reason:
                        skipped = self.summary["skipped"]
                        skipped[reason] = skipped.get(reason, 0) + 1
                    else:
                        objects = [(self.repo.filepaths.local_media_filepath_rel(media_id), FileInfo(server_name=None, file_id=media_id), metadata["length"], metadata["digest"])]
                        for width, height, kind, method, length in await self.transaction(thumbnail_rows, media_id):
                            thumb = ThumbnailInfo(width=width, height=height, type=kind, method=method, length=length)
                            objects.append((self.repo.filepaths.local_media_thumbnail_rel(media_id, width, height, kind, method),
                                            FileInfo(server_name=None, file_id=media_id, thumbnail=thumb), length, None))
                        if any(type(item[2]) is not int or not 0 <= item[2] <= self.backend.max_object_bytes for item in objects):
                            # Preserve this identity for a later larger bounded
                            # batch rather than silently advancing past its bytes.
                            self.summary["stopped_at_object_bound"] = True
                            return self.finish(started)
                        elif (self.summary["objects"] + len(objects) > self.limits.objects
                              or self.summary["bytes"] + sum(item[2] for item in objects) > self.limits.bytes):
                            self.summary["stopped_at_budget"] = True
                            return self.finish(started)
                        else:
                            for path, info, length, digest in objects:
                                if time.monotonic() >= deadline:
                                    self.summary["stopped_at_deadline"] = True
                                    return self.finish(started)
                                self.checkpoint.audit({"cursor": media_id, "outcome": "pending", "counts": self.summary})
                                try:
                                    result = await copy_object(self, path, info, length, digest)
                                except QuarantinedDigest:
                                    reason = "quarantined_digest"
                                    skipped = self.summary["skipped"]
                                    skipped[reason] = skipped.get(reason, 0) + 1
                                    break
                                self.summary[result] += 1
                                self.summary["objects"] += 1
                                self.summary["bytes"] += length
                    examined += 1
                    state["cursor"] = media_id
                    # Audit failure retains the previous durable cursor. A retry
                    # verifies already copied objects without overwriting them.
                    self.checkpoint.audit({"cursor": media_id, "outcome": reason or "verified", "counts": self.summary})
                    self.checkpoint.save(state)
        return self.finish(started)

    def finish(self, started):
        self.summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        self.summary["local_bytes_retained"] = True
        self.summary["migration_coverage_complete"] = False
        return self.summary


def validate_worker(config):
    worker = config.worker
    if (worker.worker_app != "synapse.app.generic_worker" or not worker.worker_name
            or not worker.worker_name.startswith("chatflow-media-backfill-") or worker.worker_listeners
            or worker.run_background_tasks or worker.start_pushers or worker.send_federation
            or worker.should_notify_appservices or not config.redis.redis_enabled):
        raise ValueError("Backfill requires an isolated listener-free Redis worker")
    media = config.media
    if (not media.can_load_media_repo or media.media_retention_local_media_lifetime_ms is not None
            or media.media_retention_remote_media_lifetime_ms is not None or config.modules.loaded_modules):
        raise ValueError("Backfill worker must disable retention and modules")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bounded database-authorized ciphertext backfill; local files retained")
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--max-objects", type=int, default=20)
    parser.add_argument("--max-bytes", type=int, default=32 * 1024 * 1024)
    parser.add_argument("--max-seconds", type=int, default=30)
    parser.add_argument("--max-object-bytes", type=int, default=8 * 1024 * 1024)
    args, config_options = parser.parse_known_args(argv)
    result = {"status": "FAIL", "error": "closed_backfill_failure"}
    lock_file = None
    stage = "imports"
    try:
        import fcntl
        from synapse.app import _base
        from synapse.app.generic_worker import GenericWorkerServer
        from synapse.config.homeserver import HomeServerConfig
        from synapse.logging.context import LoggingContext
        from synapse.config.logger import setup_logging
        import synapse.events
        import synapse.util.caches
        limits = Limits(objects=args.max_objects, bytes=args.max_bytes, seconds=args.max_seconds,
                        object_bytes=args.max_object_bytes)
        stage = "configuration"
        config = HomeServerConfig.load_config("Synapse bounded media backfill", config_options)
        stage = "worker_validation"
        validate_worker(config)
        stage = "homeserver_setup"
        hs = GenericWorkerServer(config.server.server_name, config=config, version_string="Synapse/1.132.0 bounded media backfill")
        synapse.events.USE_FROZEN_DICTS = config.server.use_frozen_dicts
        synapse.util.caches.TRACK_MEMORY_USAGE = config.caches.track_memory_usage
        setup_logging(hs, config, use_worker_options=True)
        hs.setup()
        hs.get_replication_streamer()
        stage = "provider_checkpoint_setup"
        runner = BackfillRunner(hs, args.checkpoint, limits)
        lock_path = runner.checkpoint.path.with_suffix(runner.checkpoint.path.suffix + ".lock")
        if lock_path.is_symlink():
            raise ValueError("Backfill checkpoint lock must not be symbolic")
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        lock_file = os.fdopen(fd, "w")
        runner.checkpoint._private(lock_path)
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        async def execute():
            nonlocal result
            execution_stage = "generic_worker_start"
            try:
                await _base.start(hs)
                # Actual GenericWorker starts Redis subscription/command channels.
                from twisted.internet.defer import ensureDeferred
                from synapse.util.async_helpers import timeout_deferred
                execution_stage = "redis_ready"
                await timeout_deferred(ensureDeferred(hs.get_outbound_redis_connection().ping()), 10, hs.get_reactor())
                execution_stage = "backfill_run"
                result = {"status": "PASS", **await runner.run()}
            except Exception as exc:
                result = {"status": "FAIL", "error": "closed_backfill_failure", "failed_stage": execution_stage,
                          "failure_kind": type(exc).__name__, **runner.summary}
            finally:
                hs.get_reactor().callLater(0, hs.get_reactor().stop)
        _base.register_start(execute)
        stage = "reactor_start"
        with LoggingContext("backfill"):
            _base.start_worker_reactor("synapse-media-backfill", config)
    except Exception as exc:
        result.update(failed_stage=stage, failure_kind=type(exc).__name__)
    finally:
        if lock_file is not None:
            lock_file.close()
    print(json.dumps(result), flush=True)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
