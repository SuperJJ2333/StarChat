"""Backfill must copy only current authoritative local media and keep local bytes."""
import asyncio
import hashlib
from contextlib import asynccontextmanager
import importlib.util
import io
from pathlib import Path
import sqlite3
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]


def module():
    path = ROOT / "third_party/synapse/chatflow_s3_backfill.py"
    assert path.exists(), "bounded authoritative Synapse backfill runner required"
    spec = importlib.util.spec_from_file_location("backfill_test", path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def database():
    db = sqlite3.connect(":memory:")
    db.executescript("""
      CREATE TABLE local_media_repository(media_id TEXT,media_length INTEGER,url_cache TEXT,quarantined_by TEXT,sha256 TEXT);
      CREATE TABLE chatflow_media_blobs(media_id TEXT,digest TEXT,retiring INTEGER);
      CREATE TABLE chatflow_media_references(media_id TEXT,deleted_ts INTEGER);
      CREATE TABLE chatflow_media_pending(media_id TEXT);
    """)
    return db


@pytest.mark.parametrize("state,reason", [("quarantined","quarantined"),("retiring","retiring"),
                                         ("pending","pending"),("unreferenced","unreferenced"),
                                         ("url","url_cache"),("incomplete","incomplete")])
def test_authoritative_eligibility_rejects_unsafe_states(state, reason):
    runner = module()
    db = database()
    db.execute("INSERT INTO local_media_repository VALUES ('abcdef',?,?,?,NULL)",
               (None if state == "incomplete" else 3, "cached" if state == "url" else None,
                "admin" if state == "quarantined" else None))
    db.execute("INSERT INTO chatflow_media_blobs VALUES ('abcdef','digest',?)", (int(state == "retiring"),))
    if state != "unreferenced":
        db.execute("INSERT INTO chatflow_media_references VALUES ('abcdef',NULL)")
    if state == "pending":
        db.execute("INSERT INTO chatflow_media_pending VALUES ('abcdef')")
    assert runner.authoritative_media(db.cursor(), "abcdef")["skip"] == reason


def test_legacy_and_referenced_cas_are_eligible_and_ids_keyset_paged():
    runner = module()
    db = database()
    for value in ("cccccc", "aaaaaa", "bbbbbb"):
        db.execute("INSERT INTO local_media_repository VALUES (?,3,NULL,NULL,NULL)", (value,))
    db.execute("INSERT INTO chatflow_media_blobs VALUES ('bbbbbb','digest',0)")
    db.execute("INSERT INTO chatflow_media_references VALUES ('bbbbbb',NULL)")
    assert runner.authoritative_media(db.cursor(), "aaaaaa")["skip"] is None
    assert runner.authoritative_media(db.cursor(), "bbbbbb")["skip"] is None
    assert runner.authoritative_media(db.cursor(), "missing")["skip"] == "missing"
    assert runner.candidate_page(db.cursor(), "aaaaaa", "cccccc", 1) == ["bbbbbb"]


def fixture(tmp_path, monkeypatch, remote=None):
    runner = module()
    root = tmp_path / "cache"
    path = root / "local_content/ab/cd/ef"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"synthetic-ciphertext")
    events = []
    backend = SimpleNamespace(cache_directory=root.resolve(), max_object_bytes=150 * 1024 * 1024,
                              write_enabled=True, prefix="synapse/", bucket="test-bucket")
    class Responder:
        def __init__(self, payload):
            self.open_file = io.BytesIO(payload)
        def __enter__(self):
            return None  # Actual upstream Responder deliberately returns None.
        def __exit__(self, *args):
            self.open_file.close()
    async def fetch(path, info):
        return Responder(remote) if remote is not None else None
    async def store(path, info):
        events.append("put")
        nonlocal remote
        remote = b"synthetic-ciphertext"
    provider = SimpleNamespace(backend=backend, store_file=store, fetch=fetch)
    async def run_io(hs, func, *args):
        return func(*args)
    monkeypatch.setattr(runner, "run_io", run_io)
    target = SimpleNamespace(hs=None, provider=provider, backend=backend)
    target.hash_local = runner.hash_local
    async def digest_blocked(digest):
        return False
    target.digest_blocked = digest_blocked
    info = SimpleNamespace(file_id="abcdef")
    return runner, target, path, info, events


def test_copy_verifies_ciphertext_and_retains_local_cache(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch)
    result = asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), None))
    assert result == "copied"
    assert events == ["put"]
    assert path.read_bytes() == b"synthetic-ciphertext"


def test_existing_collision_never_overwrites_remote(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch, b"different-ciphertext")
    with pytest.raises(RuntimeError, match="collision"):
        asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), None))
    assert events == []
    assert path.exists()


def test_existing_identical_object_is_idempotently_verified(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch, b"synthetic-ciphertext")
    assert asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), None)) == "verified"
    assert not events


def test_database_digest_mismatch_cannot_publish(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch)
    with pytest.raises(RuntimeError, match="digest"):
        asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), "0" * 64))
    assert not events


def test_missing_cache_can_only_verify_existing_s3_against_authoritative_digest(tmp_path, monkeypatch):
    payload = b"synthetic-ciphertext"
    runner, target, path, info, events = fixture(tmp_path, monkeypatch, payload)
    path.unlink()
    result = asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(payload), hashlib.sha256(payload).hexdigest()))
    assert result == "verified"
    assert not events and not path.exists()


@pytest.mark.parametrize("digest", [None, "0" * 64])
def test_missing_cache_cannot_trust_unverified_remote(tmp_path, monkeypatch, digest):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch, b"synthetic-ciphertext")
    path.unlink()
    with pytest.raises(RuntimeError):
        asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(b"synthetic-ciphertext"), digest))
    assert not events


def test_checkpoint_is_private_and_bound_to_target(tmp_path):
    runner = module()
    checkpoint = runner.Checkpoint(tmp_path / "private/state.json", "source-target-one")
    checkpoint.save({"cursor":"abcdef", "upper":"zzzzzz", "version":1, "target":"source-target-one"})
    assert checkpoint.load()["cursor"] == "abcdef"
    if hasattr(__import__("os"), "geteuid"):
        assert checkpoint.path.stat().st_mode & 0o777 == 0o600
        assert checkpoint.path.parent.stat().st_mode & 0o777 == 0o700
    with pytest.raises(ValueError, match="target"):
        runner.Checkpoint(checkpoint.path, "other-target").load()


def test_invalid_limits_rejected_before_start():
    runner = module()
    for key, value in (("objects", 0), ("bytes", 0), ("seconds", 0), ("objects", True), ("page_size", 101)):
        with pytest.raises(ValueError):
            runner.Limits(**{key:value})


@pytest.mark.parametrize("field,value", [("worker_app","synapse.app.homeserver"),("worker_name","master"),
        ("worker_listeners",[{}]),("run_background_tasks",True),("start_pushers",True),
        ("send_federation",True),("should_notify_appservices",True)])
def test_bootstrap_refuses_production_worker_duties(field, value):
    runner = module()
    worker = SimpleNamespace(worker_app="synapse.app.generic_worker", worker_name="chatflow-media-backfill-fixture",
            worker_listeners=[], run_background_tasks=False, start_pushers=False, send_federation=False,
            should_notify_appservices=False)
    media = SimpleNamespace(can_load_media_repo=True, media_retention_local_media_lifetime_ms=None,
                            media_retention_remote_media_lifetime_ms=None)
    config = SimpleNamespace(worker=worker, media=media, redis=SimpleNamespace(redis_enabled=True),
                             modules=SimpleNamespace(loaded_modules=[]))
    runner.validate_worker(config)
    setattr(worker, field, value)
    with pytest.raises(ValueError):
        runner.validate_worker(config)


@pytest.mark.parametrize("which", ["retention","modules","redis"])
def test_bootstrap_refuses_retention_modules_and_missing_redis(which):
    runner = module()
    worker = SimpleNamespace(worker_app="synapse.app.generic_worker", worker_name="chatflow-media-backfill-fixture",
            worker_listeners=[], run_background_tasks=False, start_pushers=False, send_federation=False,
            should_notify_appservices=False)
    config = SimpleNamespace(worker=worker, media=SimpleNamespace(can_load_media_repo=True,
            media_retention_local_media_lifetime_ms=1000 if which == "retention" else None,
            media_retention_remote_media_lifetime_ms=None), redis=SimpleNamespace(redis_enabled=which != "redis"),
            modules=SimpleNamespace(loaded_modules=[object()] if which == "modules" else []))
    with pytest.raises(ValueError):
        runner.validate_worker(config)


@pytest.mark.parametrize("payload,expected,raises", [(b"cipher",6,False),(b"cipher",5,True),(b"cipher",7,True)])
def test_public_responder_verification_closes_on_success_and_length_failure(tmp_path, monkeypatch, payload, expected, raises):
    runner, target, _, info, _ = fixture(tmp_path, monkeypatch)
    source = io.BytesIO(payload)
    exits = []
    class Responder:
        open_file = source
        def __enter__(self):
            return None
        def __exit__(self, *args):
            exits.append(args[0])
            source.close()
    async def fetch(path, metadata):
        assert path == "local_content/ab/cd/ef" and metadata is info
        return Responder()
    target.provider.fetch = fetch
    async def verify():
        return await runner.remote_hash(target, "local_content/ab/cd/ef", info, expected)
    if raises:
        with pytest.raises(RuntimeError, match="length"):
            asyncio.run(verify())
    else:
        assert asyncio.run(verify()) == hashlib.sha256(payload).hexdigest()
    assert source.closed and len(exits) == 1


def test_public_responder_read_failure_closes_and_permission_failure_never_puts(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch)
    source = io.BytesIO(b"synthetic-ciphertext")
    class Responder:
        open_file = source
        def __enter__(self):
            return None
        def __exit__(self, *args):
            source.close()
    async def fetch(path, info):
        return Responder()
    target.provider.fetch = fetch
    monkeypatch.setattr(runner, "hash_stream", lambda *args: (_ for _ in ()).throw(OSError("synthetic read failure")))
    with pytest.raises(OSError):
        asyncio.run(runner.remote_hash(target, "local_content/ab/cd/ef", info, len(path.read_bytes())))
    assert source.closed
    async def denied(path, info):
        raise RuntimeError("Media storage read unavailable")
    target.provider.fetch = denied
    monkeypatch.undo()
    async def run_io(hs, function, *args):
        return function(*args)
    monkeypatch.setattr(runner, "run_io", run_io)
    with pytest.raises(RuntimeError, match="unavailable"):
        asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), None))
    assert not events



def test_legacy_computed_digest_quarantine_cannot_publish(tmp_path, monkeypatch):
    runner, target, path, info, events = fixture(tmp_path, monkeypatch)
    async def blocked(digest):
        assert digest == hashlib.sha256(path.read_bytes()).hexdigest()
        return True
    target.digest_blocked = blocked
    with pytest.raises(RuntimeError, match="quarantined"):
        asyncio.run(runner.copy_object(target, "local_content/ab/cd/ef", info, len(path.read_bytes()), None))
    assert not events


def running_fixture(tmp_path, monkeypatch, length=20):
    from types import ModuleType
    import sys
    runner, target, path, info, events = fixture(tmp_path, monkeypatch)
    base = ModuleType("synapse.media._base")
    base.FileInfo = lambda **kwargs: SimpleNamespace(**kwargs)
    base.ThumbnailInfo = lambda **kwargs: SimpleNamespace(**kwargs)
    dedup = ModuleType("synapse.media.chatflow_media_dedup")
    dedup.blocked = lambda *args: False
    monkeypatch.setitem(sys.modules,"synapse.media._base",base)
    monkeypatch.setitem(sys.modules,"synapse.media.chatflow_media_dedup",dedup)
    @asynccontextmanager
    async def lock(*args):
        yield
    monkeypatch.setattr(runner,"bounded_lifecycle_lock",lock)
    instance = object.__new__(runner.BackfillRunner)
    instance.hs = None
    instance.backend = target.backend
    instance.provider = target.provider
    instance.limits = runner.Limits(object_bytes=8)
    instance.backend.max_object_bytes=8
    instance.repo = SimpleNamespace(filepaths=SimpleNamespace(local_media_filepath_rel=lambda media_id:"local_content/ab/cd/ef"))
    instance.summary = {"copied":0,"verified":0,"objects":0,"bytes":0,"skipped":{},"scan_completed":False}
    instance.checkpoint = runner.Checkpoint(tmp_path/"private/state.json","fixture")
    async def transaction(function,*args):
        if function.__name__=="upper":return "abcdef"
        if function is runner.candidate_page:return ["abcdef"] if args[0]=="" else []
        if function is runner.authoritative_media:return {"skip":None,"length":length,"digest":None}
        if function is runner.thumbnail_rows:return []
        if function is dedup.blocked:return False
        raise AssertionError("Unexpected transaction")
    instance.transaction = transaction
    return runner,instance,events


def test_object_bound_preserves_cursor_for_larger_bounded_retry(tmp_path,monkeypatch):
    runner,instance,_=running_fixture(tmp_path,monkeypatch)
    result=asyncio.run(instance.run())
    assert result.get("stopped_at_object_bound") is True
    assert instance.checkpoint.load()["cursor"]==""
    assert not result["scan_completed"]


def test_pending_audit_failure_prevents_any_put_or_cursor_advance(tmp_path,monkeypatch):
    runner,instance,events=running_fixture(tmp_path,monkeypatch)
    instance.limits.object_bytes=32
    instance.backend.max_object_bytes=32
    def failed(value):raise OSError("Synthetic audit failure")
    monkeypatch.setattr(instance.checkpoint,"audit",failed)
    with pytest.raises(OSError):asyncio.run(instance.run())
    assert not events and instance.checkpoint.load()["cursor"]==""


def test_completed_audit_failure_keeps_cursor_for_idempotent_retry(tmp_path,monkeypatch):
    runner,instance,events=running_fixture(tmp_path,monkeypatch)
    instance.limits.object_bytes=32
    instance.backend.max_object_bytes=32
    outcomes=[]
    def failed(value):
        outcomes.append(value["outcome"])
        if value["outcome"]!="pending":raise OSError("Synthetic audit failure")
    monkeypatch.setattr(instance.checkpoint,"audit",failed)
    with pytest.raises(OSError):asyncio.run(instance.run())
    assert events==["put"] and outcomes==["pending","verified"]
    assert instance.checkpoint.load()["cursor"]==""



def test_checkpoint_and_audit_disk_input_are_bounded(tmp_path):
    import os
    runner=module()
    checkpoint=runner.Checkpoint(tmp_path/"private/state.json","target")
    checkpoint.path.write_bytes(b" "*4097)
    os.chmod(checkpoint.path,0o600)
    with pytest.raises(ValueError,match="bound"):checkpoint.load()
    audit=checkpoint.path.with_suffix(".json.audit.jsonl")
    with audit.open("wb") as output:output.truncate(16*1024*1024)
    os.chmod(audit,0o600)
    with pytest.raises(ValueError,match="bound"):checkpoint.audit({"outcome":"pending"})


def test_real_database_lookup_sets_transaction_timeout_before_select():
    runner=module()
    instance=object.__new__(runner.BackfillRunner)
    queries=[]
    class Txn:
        def execute(self,sql):queries.append(sql)
    async def interaction(name,function,*args):return function(Txn(),*args)
    instance.repo=SimpleNamespace(store=SimpleNamespace(db_pool=SimpleNamespace(runInteraction=interaction)))
    def selected(txn):
        txn.execute("SELECT synthetic")
        return 1
    assert asyncio.run(instance.transaction(selected))==1
    assert queries==["SET LOCAL lock_timeout='1000ms'","SET LOCAL statement_timeout='5000ms'","SELECT synthetic"]
