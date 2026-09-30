import importlib
import importlib.util
from datetime import datetime, timedelta, timezone

import pytest

from app.core.errors import AppError
from app.modules.identity.models import AvatarUpload, User
from app.modules.media.domain import BlobStatus, MediaStatus
from app.modules.media.models import MediaBlob, MediaObject
from app.modules.media.repository import MediaRepository
from app.modules.media.storage import LocalBlobBackend
from app.modules.moments.media import MomentMediaUpload
import test_s3_integration
from test_s3_integration import request
from test_s3_storage import backend

factory = test_s3_integration.factory


def migration():
    name = 'app.integrations.media_storage_migration'
    assert importlib.util.find_spec(name), 'metadata-guarded S3 migration missing'
    return importlib.import_module(name)


def test_platform_copy_verifies_bytes_preserves_metadata_and_local(factory, tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    remote = backend()
    result = MediaRepository(factory, backend=source).ingest(request())
    audits = []
    job = migration().MediaStorageMigration(factory, source=source, target=remote,
        audit_sink=audits.append, compatible_reads_enabled=True)
    before = job.run(kind='platform', dry_run=True, limit=1)
    assert before.would_copy == 1 and before.copied == 0
    assert remote.list_page(prefix='media/').keys == ()
    report = job.run(kind='platform', dry_run=False, limit=1)
    assert report.copied == 1 and report.bytes_verified == len(request().content)
    repeat = job.run(kind='platform', dry_run=False, limit=1)
    assert repeat.already_present == 1 and repeat.copied == 0
    with factory() as session:
        blob = session.get(MediaBlob, result.blob_id)
        assert blob.status == BlobStatus.VERIFIED.value
        assert source.get(blob.storage_key) == remote.get(blob.storage_key)
    assert audits and 'storage_key' in audits[-1]
    assert 'storage_key' not in report.as_dict()


def test_migration_skips_retiring_and_deleted_parent_and_target_conflict(factory, tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    remote = backend()
    result = MediaRepository(factory, backend=source).ingest(request())
    job = migration().MediaStorageMigration(factory, source=source, target=remote,
        audit_sink=lambda _: None, compatible_reads_enabled=True)
    with factory.begin() as session:
        session.get(MediaBlob, result.blob_id).status = BlobStatus.RETIRING.value
    assert job.run(kind='platform', dry_run=False).skipped == 1
    with factory.begin() as session:
        blob = session.get(MediaBlob, result.blob_id)
        blob.status = BlobStatus.VERIFIED.value
        key = blob.storage_key
        session.get(MediaObject, result.media_id).status = MediaStatus.DELETED.value
    assert job.run(kind='platform', dry_run=False).skipped == 1
    with factory.begin() as session:
        session.get(MediaObject, result.media_id).status = MediaStatus.ACTIVE.value
    remote.put(key, b'wrong-content')
    with pytest.raises(AppError) as caught:
        job.run(kind='platform', dry_run=False)
    assert caught.value.code == 'MEDIA_MIGRATION_CONTENT_MISMATCH'
    assert remote.get(key) == b'wrong-content'


def test_enforce_requires_compatible_reads_and_private_audit(factory, tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    for enabled, audit in ((False, lambda _: None), (True, None)):
        job = migration().MediaStorageMigration(factory, source=source, target=backend(),
            audit_sink=audit, compatible_reads_enabled=enabled)
        with pytest.raises(ValueError):
            job.run(kind='platform', dry_run=False)


def test_legacy_current_avatar_and_completed_moment_migrate_without_reviving_cancelled(factory, tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    remote = backend()
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.get(User, 'unit-user').avatar_object_key = 'avatars/unit-user/current.png'
        for number, status in ((0, 'COMPLETED'), (1, 'CANCELLED')):
            key = 'avatars/unit-user/current.png' if number == 0 else 'avatars/unit-user/cancelled.png'
            session.add(AvatarUpload(id=str(number), owner_id='unit-user', mime_type='image/png',
                byte_size=3, status=status, object_key=key, idempotency_key=str(number),
                created_at=now, expires_at=now + timedelta(days=1)))
            source.put(key, b'abc')
        session.add(MomentMediaUpload(id='moment-upload', owner_id='unit-user', file_name='unit.png',
            mime_type='image/png', byte_size=3, status='COMPLETED', object_key='moments/unit-user/a.png',
            purpose='MOMENT_IMAGE', idempotency_key='moment', created_at=now, expires_at=now + timedelta(days=1)))
        source.put('moments/unit-user/a.png', b'abc')
    job = migration().MediaStorageMigration(factory, source=source, target=remote,
        audit_sink=lambda _: None, compatible_reads_enabled=True)
    avatar = job.run(kind='avatars', dry_run=False)
    moment = job.run(kind='moments', dry_run=False)
    assert avatar.copied == 1 and avatar.skipped == 1 and moment.copied == 1
    assert not remote.exists('avatars/unit-user/cancelled.png')


def test_local_migration_read_has_explicit_allocation_bound(tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    source.put('media/user/scope/a.bin', b'12345')
    assert callable(getattr(source, 'get_bounded', None)), 'bounded local migration read missing'
    with pytest.raises(AppError):
        source.get_bounded('media/user/scope/a.bin', max_bytes=4)


def test_migration_rejects_metadata_key_in_wrong_isolation_domain(factory, tmp_path):
    source = LocalBlobBackend(root=str(tmp_path))
    remote = backend()
    result = MediaRepository(factory, backend=source).ingest(request())
    with factory.begin() as session:
        session.get(MediaBlob, result.blob_id).storage_key = 'media/e2ee/wrongscope/a.bin'
    source.put('media/e2ee/wrongscope/a.bin', request().content)
    job = migration().MediaStorageMigration(factory, source=source, target=remote,
        audit_sink=lambda _: None, compatible_reads_enabled=True)
    with pytest.raises(AppError) as caught:
        job.run(kind='platform', dry_run=False)
    assert caught.value.code == 'MEDIA_MIGRATION_CONTENT_MISMATCH'
    assert remote.list_page(prefix='media/').keys == ()
