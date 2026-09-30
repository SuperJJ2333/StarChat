from datetime import datetime, timezone
from pathlib import Path
import importlib.util

import pytest
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import _build_media_platform_service
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.media.domain import BlobStatus, DigestKind, MediaKind
from app.modules.media.models import MediaBlob
from app.modules.media.reconcile import MediaReconciler
from app.modules.media.repository import IngestRequest, MediaRepository
from test_s3_storage import S3Transport, backend, client_error


@pytest.fixture
def factory():
    engine = create_engine('sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False}, poolclass=StaticPool)
    Base.metadata.create_all(engine)
    session_factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with session_factory.begin() as session:
        session.add(User(id='unit-user', username='unituser', username_normalized='unituser',
            email='unit@example.invalid', email_normalized='unit@example.invalid', password_hash='hash',
            status=AccountStatus.ACTIVE, email_verified_at=now, created_at=now, updated_at=now))
    yield session_factory
    engine.dispose()


def request():
    return IngestRequest(owner_id='unit-user', origin_domain='unit', kind=MediaKind.FILE,
        mime='application/octet-stream', content=b'opaque-unit-content', digest_kind=DigestKind.PLAINTEXT)


def test_platform_and_legacy_readers_share_s3_bytes(factory, tmp_path):
    remote = backend()
    settings = Settings(_env_file=None, environment='test', avatar_storage_root=str(tmp_path),
        avatar_url_signing_secret='unit-avatar-signing-secret-32-bytes')
    legacy = LocalPrivateObjectStorage(root=str(tmp_path), backend=remote,
        signing_secret=settings.avatar_url_signing_secret, public_base_url='https://example.invalid')
    service = _build_media_platform_service(settings, factory, legacy)
    upload = request()
    result = service.ingest(owner_id=upload.owner_id, origin_domain=upload.origin_domain,
        kind=upload.kind, mime=upload.mime, content=upload.content, digest_kind=upload.digest_kind)
    with factory() as session:
        blob = session.get(MediaBlob, result.blob_id)
    assert remote.exists(blob.storage_key), 'platform must use the legacy shared byte backend'
    assert legacy.get(blob.storage_key) == request().content
    assert not (tmp_path / blob.storage_key).exists()


def test_s3_reconciler_resumes_bounded_discovery_and_reads_remote_bytes(factory):
    remote = backend()
    for number in range(3):
        remote.put(f'media/e2ee/scope/{number}.bin', b'cipher' + bytes([number]))
    reconciler = MediaReconciler(factory, backend=remote)
    first = reconciler.run(dry_run=False, limit=2)
    assert first.scanned_files == 2 and first.rebuilt == 2
    assert first.next_storage_cursor
    next_page = reconciler.run(dry_run=False, limit=2, storage_cursor=first.next_storage_cursor)
    assert next_page.scanned_files == 1 and next_page.rebuilt == 1
    with factory() as session:
        blobs = session.query(MediaBlob).all()
    assert len(blobs) == 3
    assert all(blob.digest_kind == DigestKind.CIPHERTEXT.value for blob in blobs)


def test_reconcile_permission_failure_does_not_invalidate_metadata(factory):
    transport = S3Transport()
    remote = backend(transport)
    result = MediaRepository(factory, backend=remote).ingest(request())
    transport.failure = client_error('AccessDenied', 403)
    reconciler = MediaReconciler(factory, backend=remote)
    with pytest.raises(AppError) as caught:
        reconciler.run(dry_run=False)
    assert caught.value.code == 'MEDIA_STORAGE_UNAVAILABLE'
    with factory() as session:
        assert session.get(MediaBlob, result.blob_id).status == BlobStatus.VERIFIED.value


def test_worker_avatar_reader_uses_shared_backend(tmp_path):
    path = Path(__file__).resolve().parents[3] / 'services/business-worker/app/integrations/avatar_reader.py'
    spec = importlib.util.spec_from_file_location('unit_worker_avatar_reader', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    remote = backend()
    remote.put('avatars/unit-user/a.png', b'avatar')
    reader = module.LocalPrivateAvatarReader(str(tmp_path), backend=remote)
    assert reader.get('avatars/unit-user/a.png') == b'avatar'
    with pytest.raises(AppError) as caught:
        reader.get('avatars/unit-user/missing.png')
    assert caught.value.code == 'AVATAR_NOT_FOUND'


def test_reconciler_uses_wrapped_legacy_byte_backend(factory, tmp_path):
    remote = backend()
    result = MediaRepository(factory, backend=remote).ingest(request())
    legacy = LocalPrivateObjectStorage(root=str(tmp_path), backend=remote,
        signing_secret='unit-avatar-signing-secret-32-bytes', public_base_url='https://example.invalid')
    report = MediaReconciler(factory, backend=legacy).run(dry_run=False)
    assert report.invalidated == 0
    with factory() as session:
        assert session.get(MediaBlob, result.blob_id).status == BlobStatus.VERIFIED.value
