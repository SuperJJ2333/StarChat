"""Production adapter with SQLite and real files; Synapse transport types mocked.

This tests adapter races/recovery, not a running Synapse/Redis/PostgreSQL cluster.
"""
import asyncio
import hashlib
import importlib.util
from io import BytesIO
from pathlib import Path
import sqlite3
import sys
from types import ModuleType, SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / "third_party/synapse"


class MediaError(Exception):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


class MXC:
    def __init__(self, server_name, media_id):
        self.server_name, self.media_id = server_name, media_id


@pytest.fixture
def repository(tmp_path, monkeypatch):
    for name, symbols in {
        "synapse.util.async_helpers": {"Linearizer": lambda **_: SimpleNamespace(queue=lambda _: local_mutex)},
        "synapse.api.errors": {"SynapseError": MediaError},
        "matrix_common.types.mxc_uri": {"MXCUri": MXC},
        "synapse.media._base": {"FileInfo": lambda **kwargs: SimpleNamespace(**kwargs)},
    }.items():
        module = ModuleType(name)
        module.__dict__.update(symbols)
        monkeypatch.setitem(sys.modules, name, module)
    spec = importlib.util.spec_from_file_location("dedup_adapter", BUNDLE / "chatflow_media_dedup.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    db = sqlite3.connect(":memory:")
    db.executescript("""CREATE TABLE local_media_repository (
       media_id TEXT PRIMARY KEY, media_type TEXT, media_length BIGINT, upload_name TEXT,
       created_ts BIGINT, url_cache TEXT, last_access_ts BIGINT, quarantined_by TEXT,
       safe_from_quarantine BOOLEAN, user_id TEXT, authenticated BOOLEAN, sha256 TEXT);
       CREATE TABLE remote_media_cache (sha256 TEXT, quarantined_by TEXT);""")
    db.executescript((BUNDLE / "99_chatflow_media.sql").read_text(encoding="utf-8"))
    mutex = asyncio.Lock()
    local_mutex = asyncio.Lock()

    class Repo:
        def __init__(self):
            self.db = db
            self.now, self.uploads = 10, 0
            self.fail_publish = False
            self.fail_after_unlink = False
            self.refuse_remove = False
            self.server_name = "test.invalid"
            self.clock = SimpleNamespace(time_msec=lambda: self.now)
            self.hs = SimpleNamespace(get_worker_locks_handler=lambda: SimpleNamespace(acquire_lock=lambda *_: mutex))
            self.store = SimpleNamespace(db_pool=SimpleNamespace(runInteraction=self.txn), get_local_media=self.get_media)
            self.media_storage = SimpleNamespace(ensure_media_is_in_local_cache=self.ensure_file)

        async def txn(self, name, fn, *args):
            await asyncio.sleep(0)
            with db:
                result = fn(db.cursor(), *args)
                if self.fail_publish and fn.__name__ == "publish":
                    raise RuntimeError("publish failed")
                return result

        async def get_media(self, media_id):
            row = db.execute("SELECT user_id FROM local_media_repository WHERE media_id=?", (media_id,)).fetchone()
            return SimpleNamespace(user_id=row[0]) if row else None

        async def ensure_file(self, info):
            file = tmp_path / info.file_id
            if not file.exists():
                raise FileNotFoundError()
            return str(file)

        async def _chatflow_create_content_original(self, kind, name, content, length, user, _chatflow_media_id=None):
            self.uploads += 1
            media_id = _chatflow_media_id or str(self.uploads)
            data = content.read()
            (tmp_path / media_id).write_bytes(data)
            await asyncio.sleep(0)
            with db:
                db.execute("INSERT INTO local_media_repository VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, 0, ?, 1, ?)",
                           (media_id, kind, length, name, self.now, user.to_string(), hashlib.sha256(data).hexdigest()))
            return MXC(self.server_name, media_id)

        async def _chatflow_remove_local_media_original(self, media_ids):
            if self.refuse_remove:
                return [], 0
            for media_id in media_ids:
                (tmp_path / media_id).unlink(missing_ok=True)
                if self.fail_after_unlink:
                    raise RuntimeError("crashed after unlink")
                with db:
                    db.execute("DELETE FROM local_media_repository WHERE media_id=?", (media_id,))
            return media_ids, len(media_ids)

    monkeypatch.setenv("CHATFLOW_MEDIA_DEDUP", "true")
    monkeypatch.setenv("CHATFLOW_MEDIA_RETENTION_MS", "100")
    repo = Repo()
    yield module.ContentAddressedMedia(repo), repo, tmp_path
    db.close()


async def upload(adapter, user="alice", data=b"synthetic ciphertext"):
    return await adapter.create("application/octet-stream", "cipher", BytesIO(data), len(data),
                                SimpleNamespace(to_string=lambda: user))


@pytest.mark.asyncio
async def test_concurrent_different_uploaders_publish_one_file(repository):
    adapter, repo, directory = repository
    results = await asyncio.gather(*(upload(adapter, str(n)) for n in range(20)))
    assert len({item.media_id for item in results}) == 1
    assert repo.uploads == 1
    assert len(list(directory.iterdir())) == 1
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_references").fetchone()[0] == 20


@pytest.mark.asyncio
async def test_local_waiters_do_not_contend_on_distributed_lock(repository):
    from contextlib import asynccontextmanager
    adapter, repo, _ = repository
    waiting, peak = 0, 0
    mutex = asyncio.Lock()

    @asynccontextmanager
    async def distributed(*_):
        nonlocal waiting, peak
        waiting += 1
        peak = max(peak, waiting)
        try:
            async with mutex:
                await asyncio.sleep(0)
                yield
        finally:
            waiting -= 1

    repo.hs.get_worker_locks_handler = lambda: SimpleNamespace(acquire_lock=distributed)
    await asyncio.gather(*(upload(adapter, str(n)) for n in range(8)))
    assert peak == 1


@pytest.mark.asyncio
async def test_delete_purge_and_reupload_do_not_race_into_dead_id(repository):
    adapter, repo, directory = repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    _, second = await asyncio.gather(adapter.purge([first.media_id]), upload(adapter, "bob"))
    assert (directory / second.media_id).read_bytes() == b"synthetic ciphertext"
    assert repo.db.execute("SELECT user_id FROM chatflow_media_user_view").fetchall() == [("bob",)]


@pytest.mark.asyncio
async def test_flag_off_keeps_shared_reference_delete_semantics(repository, monkeypatch):
    adapter, repo, directory = repository
    first = await upload(adapter)
    assert (await upload(adapter, "bob")).media_id == first.media_id
    monkeypatch.setenv("CHATFLOW_MEDIA_DEDUP", "false")
    other = await upload(adapter, "carol")
    assert other.media_id != first.media_id
    await adapter.delete([first.media_id], "alice")
    assert (directory / first.media_id).exists()
    assert repo.db.execute("SELECT user_id FROM chatflow_media_user_view ORDER BY user_id").fetchall() == [("bob",), ("carol",)]


@pytest.mark.asyncio
async def test_quarantine_and_missing_file_never_return_success(repository):
    adapter, repo, directory = repository
    first = await upload(adapter)
    repo.db.execute("UPDATE local_media_repository SET quarantined_by='admin'")
    repo.db.commit()
    with pytest.raises(MediaError) as error:
        await upload(adapter, "bob")
    assert error.value.code == 403
    repo.db.execute("UPDATE local_media_repository SET quarantined_by=NULL")
    repo.db.commit()
    (directory / first.media_id).unlink()
    with pytest.raises(MediaError) as error:
        await upload(adapter, "bob")
    assert error.value.code == 503


@pytest.mark.asyncio
async def test_failed_publish_has_no_reference_or_success(repository):
    adapter, repo, directory = repository
    repo.fail_publish = True
    with pytest.raises(RuntimeError):
        await upload(adapter)
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 0
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_references").fetchone()[0] == 0
    assert list(directory.iterdir()) == []
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_user_view").fetchone()[0] == 0
    repo.fail_publish = False
    assert (await upload(adapter)).media_id
    assert len(list(directory.iterdir())) == 1
    assert repo.db.execute("SELECT count(*) FROM local_media_repository").fetchone()[0] == 1


@pytest.mark.asyncio
async def test_purge_retries_after_unlink_failure(repository):
    adapter, repo, directory = repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    repo.fail_after_unlink = True
    with pytest.raises(RuntimeError):
        await adapter.purge([first.media_id])
    repo.fail_after_unlink = False
    assert await adapter.purge([first.media_id]) == ([first.media_id], 1)
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 0
    assert not (directory / first.media_id).exists()


@pytest.mark.asyncio
async def test_upload_recovers_retiring_id_after_failed_purge(repository):
    adapter, repo, directory = repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    repo.fail_after_unlink = True
    with pytest.raises(RuntimeError):
        await adapter.purge([first.media_id])
    repo.fail_after_unlink = False
    second = await upload(adapter, "bob")
    assert (directory / second.media_id).exists()
    assert second.media_id != first.media_id


@pytest.mark.asyncio
async def test_failed_compensation_is_durable_and_retry_does_not_duplicate(repository):
    adapter, repo, directory = repository
    repo.fail_publish, repo.refuse_remove = True, True
    with pytest.raises(RuntimeError):
        await upload(adapter)
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_user_view").fetchone()[0] == 0
    assert len(list(directory.iterdir())) == 1
    repo.fail_publish = False
    with pytest.raises(MediaError):
        await upload(adapter, "bob")
    assert repo.uploads == 1
    repo.refuse_remove = False
    await upload(adapter, "bob")
    assert len(list(directory.iterdir())) == 1
    assert repo.db.execute("SELECT user_id FROM chatflow_media_user_view").fetchall() == [("bob",)]
