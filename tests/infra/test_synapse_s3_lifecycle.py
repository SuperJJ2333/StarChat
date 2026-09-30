"""S3 deletion must participate in the existing authoritative reference lifecycle."""
from types import SimpleNamespace

import pytest

from test_media_dedup_lifecycle import repository, upload


@pytest.fixture
def remote_repository(repository):
    adapter, repo, root = repository

    class Backend:
        objects = set()
        fail = False

        async def delete_local_media(self, media_id):
            if self.fail:
                raise RuntimeError("synthetic storage failure")
            self.objects.discard(media_id)

    backend = Backend()
    repo.media_storage.storage_providers = [SimpleNamespace(backend=backend)]
    original = repo._chatflow_create_content_original

    async def create(*args, **kwargs):
        result = await original(*args, **kwargs)
        backend.objects.add(result.media_id)
        return result

    repo._chatflow_create_content_original = create
    return adapter, repo, root, backend


@pytest.mark.asyncio
async def test_shared_reference_and_quarantine_keep_s3_ciphertext(remote_repository):
    adapter, repo, root, remote = remote_repository
    first = await upload(adapter)
    assert (await upload(adapter, "bob")).media_id == first.media_id
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    assert await adapter.purge([first.media_id]) == ([], 0)
    await adapter.delete([first.media_id], "bob")
    repo.db.execute("UPDATE local_media_repository SET quarantined_by='admin'")
    repo.db.commit()
    repo.now = 400
    assert await adapter.purge([first.media_id]) == ([], 0)
    assert first.media_id in remote.objects
    assert (root / first.media_id).exists()


@pytest.mark.asyncio
async def test_remote_purge_failure_keeps_retiring_and_local_bytes_then_retry(remote_repository):
    adapter, repo, root, remote = remote_repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    remote.fail = True
    with pytest.raises(RuntimeError):
        await adapter.purge([first.media_id])
    assert repo.db.execute("SELECT retiring FROM chatflow_media_blobs").fetchone()[0] == 1
    assert (root / first.media_id).exists()
    assert first.media_id in remote.objects
    remote.fail = False
    assert await adapter.purge([first.media_id]) == ([first.media_id], 1)
    assert not remote.objects
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 0


@pytest.mark.asyncio
async def test_same_digest_retry_completes_failed_purge_and_allocates_new_identity(remote_repository):
    adapter, repo, root, remote = remote_repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    remote.fail = True
    with pytest.raises(RuntimeError):
        await adapter.purge([first.media_id])
    with pytest.raises(RuntimeError):
        await upload(adapter, "bob")
    remote.fail = False
    second = await upload(adapter, "bob")
    assert second.media_id != first.media_id
    assert remote.objects == {second.media_id}


@pytest.mark.asyncio
async def test_publish_compensation_keeps_pending_until_remote_cleanup_succeeds(remote_repository):
    adapter, repo, root, remote = remote_repository
    repo.fail_publish = True
    remote.fail = True
    with pytest.raises(RuntimeError):
        await upload(adapter)
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_pending").fetchone()[0] == 1
    repo.fail_publish = False
    remote.fail = False
    next_upload = await upload(adapter)
    assert remote.objects == {next_upload.media_id}
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_pending").fetchone()[0] == 0


@pytest.mark.asyncio
async def test_non_cas_delete_also_cleans_remote_and_respects_ownership(remote_repository, monkeypatch):
    adapter, repo, root, remote = remote_repository
    monkeypatch.setenv("CHATFLOW_MEDIA_DEDUP", "false")
    first = await upload(adapter)
    assert await adapter.delete([first.media_id], "bob") == ([], 0)
    assert first.media_id in remote.objects
    assert await adapter.delete([first.media_id], "alice") == ([first.media_id], 1)
    assert first.media_id not in remote.objects
    assert not (root / first.media_id).exists()


@pytest.mark.asyncio
async def test_local_unlink_failure_after_remote_delete_keeps_recoverable_retiring_state(remote_repository):
    adapter, repo, root, remote = remote_repository
    first = await upload(adapter)
    await adapter.delete([first.media_id], "alice")
    repo.now = 200
    repo.fail_after_unlink = True
    with pytest.raises(RuntimeError):
        await adapter.purge([first.media_id])
    assert first.media_id not in remote.objects
    assert not (root / first.media_id).exists()
    assert repo.db.execute("SELECT retiring FROM chatflow_media_blobs").fetchone()[0] == 1
    repo.fail_after_unlink = False
    assert await adapter.purge([first.media_id]) == ([first.media_id], 1)
    assert repo.db.execute("SELECT count(*) FROM chatflow_media_blobs").fetchone()[0] == 0


@pytest.mark.asyncio
async def test_mixed_batch_partial_failure_is_recoverable_without_active_reference_delete(remote_repository):
    adapter, repo, root, remote = remote_repository
    one = await upload(adapter, data=b"cipher1")
    two = await upload(adapter, data=b"cipher2")
    active = await upload(adapter, "bob", data=b"cipher3")
    await adapter.delete([one.media_id, two.media_id], "alice")
    repo.now = 200
    original = remote.delete_local_media

    async def cleanup(media_id):
        if media_id == two.media_id:
            raise RuntimeError("synthetic partial storage failure")
        await original(media_id)

    remote.delete_local_media = cleanup
    with pytest.raises(RuntimeError):
        await adapter.purge([one.media_id, two.media_id, active.media_id])
    assert remote.objects == {two.media_id, active.media_id}
    assert (root / active.media_id).exists()
    assert (root / two.media_id).exists()
    remote.delete_local_media = original
    assert await adapter.purge([one.media_id, two.media_id, active.media_id]) == ([one.media_id, two.media_id], 2)
    assert remote.objects == {active.media_id}
