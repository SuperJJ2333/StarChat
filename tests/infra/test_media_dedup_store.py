"""Exercise production SQL on a real transactional SQLite database."""
import importlib.util
from pathlib import Path
import sqlite3

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def store():
    source = ROOT / "third_party/synapse/chatflow_media_dedup.py"
    assert source.exists(), "reference lifecycle implementation is missing"
    spec = importlib.util.spec_from_file_location("dedup_under_test", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE local_media_repository (
          media_id TEXT PRIMARY KEY, media_type TEXT, media_length BIGINT,
          upload_name TEXT, created_ts BIGINT, url_cache TEXT, last_access_ts BIGINT,
          quarantined_by TEXT, safe_from_quarantine BOOLEAN, user_id TEXT,
          authenticated BOOLEAN, sha256 TEXT);
        CREATE TABLE remote_media_cache (sha256 TEXT, quarantined_by TEXT);
    """)
    db.executescript((ROOT / "third_party/synapse/99_chatflow_media.sql").read_text(encoding="utf-8"))
    yield module, db
    db.close()


def seed(db, media="shared", digest="a" * 64, owner="alice"):
    db.execute("INSERT INTO local_media_repository VALUES (?, 'application/octet-stream', 12, 'cipher', 1, NULL, NULL, NULL, 0, ?, 1, ?)",
               (media, owner, digest))


def register(module, db, user="alice", now=10):
    module.publish(db.cursor(), "a" * 64, "shared", user, now,
                   "application/octet-stream", "cipher", 12)


def test_shared_id_independent_references_and_idempotent_reactivation(store):
    module, db = store
    seed(db)
    register(module, db)
    register(module, db, "bob")
    assert db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 1
    assert module.logical_delete(db.cursor(), ["shared"], "alice", 20) == ["shared"]
    assert db.execute("SELECT user_id FROM chatflow_media_user_view").fetchall() == [("bob",)]
    assert not module.collectible(db.cursor(), "shared", 10000, 100)
    register(module, db, "alice", 30)
    register(module, db, "alice", 31)
    assert db.execute("SELECT count(*) FROM chatflow_media_references").fetchone()[0] == 2


def test_last_reference_grace_and_reuse_cancel_collection(store):
    module, db = store
    seed(db)
    register(module, db)
    module.logical_delete(db.cursor(), ["shared"], "alice", 20)
    assert not module.collectible(db.cursor(), "shared", 119, 100)
    assert module.collectible(db.cursor(), "shared", 120, 100)
    register(module, db, "bob", 121)
    assert not module.collectible(db.cursor(), "shared", 10000, 100)


def test_deleted_reference_does_not_fall_back_to_original_owner(store):
    module, db = store
    seed(db)
    seed(db, "legacy", "b" * 64)
    register(module, db)
    module.logical_delete(db.cursor(), ["shared"], None, 20)
    assert db.execute("SELECT media_id FROM chatflow_media_user_view").fetchall() == [("legacy",)]


def test_quarantine_checked_without_background_index_gate(store):
    module, db = store
    seed(db)
    register(module, db)
    db.execute("UPDATE local_media_repository SET quarantined_by='admin'")
    assert module.blocked(db.cursor(), "a" * 64)
    module.logical_delete(db.cursor(), ["shared"], None, 20)
    assert not module.collectible(db.cursor(), "shared", 10000, 100)
    db.execute("UPDATE local_media_repository SET quarantined_by=NULL")
    db.execute("INSERT INTO remote_media_cache VALUES (?, 'admin')", ("a" * 64,))
    assert module.blocked(db.cursor(), "a" * 64)


def test_publish_rollback_and_unique_digest_prevent_duplicate_canonical(store):
    module, db = store
    seed(db)
    db.commit()
    with pytest.raises(RuntimeError):
        with db:
            register(module, db)
            raise RuntimeError("transaction failure")
    assert db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 0
    register(module, db)
    with pytest.raises(ValueError):
        module.publish(db.cursor(), "a" * 64, "other", "bob", 20, "x", "x", 12)
    assert db.execute("SELECT media_id FROM chatflow_media_blobs").fetchall() == [("shared",)]


def test_reference_metadata_and_quota_are_per_user(store):
    module, db = store
    seed(db)
    register(module, db)
    module.publish(db.cursor(), "a" * 64, "shared", "bob", 25,
                   "image/png", "bob.png", 12)
    assert db.execute("SELECT upload_name,created_ts,media_length FROM chatflow_media_user_view WHERE user_id='bob'").fetchone() == ("bob.png", 25, 12)
