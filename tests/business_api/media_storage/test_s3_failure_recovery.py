from datetime import timedelta

import pytest

from app.core.errors import AppError
from app.modules.media.domain import BlobStatus, GcMode, MediaStatus
from app.modules.media.lifecycle import MediaGarbageCollector
from app.modules.media.models import MediaBlob, MediaObject
from app.modules.media.reconcile import MediaReconciler
from app.modules.media.repository import MediaRepository, utcnow
from app.modules.media.storage import LocalBlobBackend
import test_s3_integration
from test_s3_integration import request
from test_s3_storage import S3Transport, backend, client_error, implementation

factory = test_s3_integration.factory


def test_gc_failure_keeps_recoverable_state_and_retry_deletes_both(factory, tmp_path):
    local = LocalBlobBackend(root=str(tmp_path))
    transport = S3Transport()
    remote = backend(transport)
    dual = implementation().DualReadBlobBackend(primary=remote, fallback=local)
    result = MediaRepository(factory, backend=dual).ingest(request())
    with factory.begin() as session:
        blob = session.get(MediaBlob, result.blob_id)
        key = blob.storage_key
        media = session.get(MediaObject, result.media_id)
        media.status = MediaStatus.ORPHAN.value
        media.unreferenced_at = utcnow() - timedelta(days=60)
    local.put(key, request().content)
    collector = MediaGarbageCollector(factory, backend=dual)
    transport.failure = client_error('AccessDenied', 403)
    with pytest.raises(AppError):
        collector.run(mode=GcMode.ENFORCE)
    with factory() as session:
        assert session.get(MediaBlob, result.blob_id).status == BlobStatus.RETIRING.value
        assert session.get(MediaObject, result.media_id).status == MediaStatus.DELETING.value
    assert local.exists(key)
    transport.failure = None
    report = collector.run(mode=GcMode.ENFORCE)
    assert report.collected == 1
    assert not remote.exists(key) and not local.exists(key)
    with factory() as session:
        assert session.get(MediaBlob, result.blob_id).status == BlobStatus.DELETED.value


def test_stale_remote_copy_does_not_revive_deleted_metadata(factory):
    remote = backend()
    result = MediaRepository(factory, backend=remote).ingest(request())
    with factory.begin() as session:
        session.get(MediaBlob, result.blob_id).status = BlobStatus.DELETED.value
    report = MediaReconciler(factory, backend=remote).run(dry_run=False)
    assert report.rebuilt == 0
    with factory() as session:
        assert session.get(MediaBlob, result.blob_id).status == BlobStatus.DELETED.value


def test_sdk_client_keeps_default_credential_chain_and_bounded_retry(monkeypatch):
    import boto3
    values = {}
    def create_client(service, **kwargs):
        values.update(kwargs)
        return S3Transport()
    monkeypatch.setattr(boto3, 'client', create_client)
    implementation().S3BlobBackend(bucket='unit-bucket', region='ap-east-1')
    assert not any('key' in key or 'token' in key for key in values)
    assert values['config'].connect_timeout == 3
    assert values['config'].retries['total_max_attempts'] == 3


def test_dual_listing_rejects_replayed_cursor_for_different_prefix(tmp_path):
    remote = backend()
    remote.put('media/user/scope/a.bin', b'a')
    dual = implementation().DualReadBlobBackend(primary=remote,
        fallback=LocalBlobBackend(root=str(tmp_path)))
    page = dual.list_page(prefix='media/', limit=1)
    with pytest.raises(AppError):
        dual.list_page(prefix='avatars/', cursor=page.next_cursor)
