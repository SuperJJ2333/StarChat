from datetime import datetime, timezone
from io import BytesIO
from types import SimpleNamespace
from urllib.parse import urlparse

import httpx
from PIL import Image
import pytest
from sqlalchemy import event, select

from app.core.config import Settings
from app.core.errors import AppError
from app.core.outbox import OutboxEvent
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.main import create_app
from app.modules.identity.models import User
from app.modules.identity.profile import ProfileService
from app.modules.media.storage import LocalBlobBackend
import test_s3_integration
from test_s3_storage import S3Transport, backend, client_error, implementation

factory = test_s3_integration.factory


def components(factory, tmp_path):
    transport = S3Transport()
    remote = backend(transport)
    local = LocalBlobBackend(root=str(tmp_path))
    storage = LocalPrivateObjectStorage(root=str(tmp_path),
        backend=implementation().DualReadBlobBackend(primary=remote, fallback=local),
        signing_secret='unit-avatar-signing-secret-32-bytes', public_base_url='https://example.invalid')
    service = ProfileService(factory, storage=storage)
    key = 'avatars/unit-user/old.png'
    storage.put(key, b'old-avatar')
    local.put(key, b'old-avatar')
    with factory.begin() as session:
        user = session.get(User, 'unit-user')
        user.avatar_object_key = key
        user.profile_updated_at = datetime.now(timezone.utc)
    return service, storage, transport, remote, local, key


def cleanup_event(factory):
    with factory() as session:
        rows = list(session.scalars(select(OutboxEvent).where(
            OutboxEvent.topic == 'identity.avatar.cleanup')))
        assert len(rows) == 1, 'retirement must commit one durable cleanup event'
        row = rows[0]
        return SimpleNamespace(topic=row.topic, event_type=row.event_type,
            aggregate_type=row.aggregate_type, aggregate_id=row.aggregate_id,
            payload=row.payload, headers=row.event_headers)


def test_delete_outage_retry_cleans_both_and_deduplicates_receipt(factory, tmp_path):
    service, _, transport, remote, local, key = components(factory, tmp_path)
    transport.failure = client_error('AccessDenied', 403)
    with pytest.raises(AppError):
        service.delete_avatar('unit-user', idempotency_key='delete-1', trace_id='unit', source_ip=None)
    cleanup_event(factory)
    with factory() as session:
        assert session.get(User, 'unit-user').avatar_object_key is None
    transport.failure = None
    service.delete_avatar('unit-user', idempotency_key='delete-1', trace_id='unit', source_ip=None)
    cleanup_event(factory)
    assert not remote.exists(key) and not local.exists(key)


def test_replace_outage_retry_preserves_new_and_removes_old(factory, tmp_path):
    service, _, transport, remote, local, key = components(factory, tmp_path)
    output = BytesIO()
    Image.new('RGB', (2, 2)).save(output, format='PNG')
    content = output.getvalue()
    upload = service.begin_avatar_upload('unit-user', mime_type='image/png',
        byte_size=len(content), idempotency_key='upload-1')
    service.put_avatar_content('unit-user', upload.id, content_type='image/png', content=content)
    original_delete = transport.delete_object
    transport.delete_object = lambda **kwargs: (_ for _ in ()).throw(client_error('AccessDenied', 403))
    with pytest.raises(AppError):
        service.complete_avatar_upload('unit-user', upload.id,
            idempotency_key='complete-1', trace_id='unit', source_ip=None)
    cleanup_event(factory)
    transport.delete_object = original_delete
    result = service.complete_avatar_upload('unit-user', upload.id,
        idempotency_key='complete-1', trace_id='unit', source_ip=None)
    assert result.avatar_url and remote.get(upload.object_key) == content
    assert not remote.exists(key) and not local.exists(key)


def test_delete_commit_failure_never_deletes_authoritative_bytes(factory, tmp_path):
    service, _, _, remote, local, key = components(factory, tmp_path)
    def abort_commit(session):
        if not session.in_nested_transaction():
            raise RuntimeError('unit commit rejected')
    event.listen(factory.class_, 'before_commit', abort_commit)
    try:
        with pytest.raises(RuntimeError, match='unit commit rejected'):
            service.delete_avatar('unit-user', idempotency_key='delete-1', trace_id='unit', source_ip=None)
    finally:
        event.remove(factory.class_, 'before_commit', abort_commit)
    with factory() as session:
        assert session.get(User, 'unit-user').avatar_object_key == key
        assert not list(session.scalars(select(OutboxEvent)))
    assert remote.exists(key) and local.exists(key)


@pytest.mark.parametrize('replace_existing', [True, False])
def test_create_replace_commit_failure_retains_uploaded_bytes(factory, tmp_path, replace_existing):
    service, _, _, remote, local, key = components(factory, tmp_path)
    if not replace_existing:
        with factory.begin() as session:
            session.get(User, 'unit-user').avatar_object_key = None
    output = BytesIO()
    Image.new('RGB', (2, 2)).save(output, format='PNG')
    content = output.getvalue()
    upload = service.begin_avatar_upload('unit-user', mime_type='image/png',
        byte_size=len(content), idempotency_key='upload-1')
    service.put_avatar_content('unit-user', upload.id, content_type='image/png', content=content)
    def abort_commit(session):
        if not session.in_nested_transaction():
            raise RuntimeError('unit commit rejected')
    event.listen(factory.class_, 'before_commit', abort_commit)
    try:
        with pytest.raises(RuntimeError, match='unit commit rejected'):
            service.complete_avatar_upload('unit-user', upload.id,
                idempotency_key='complete-1', trace_id='unit', source_ip=None)
    finally:
        event.remove(factory.class_, 'before_commit', abort_commit)
    with factory() as session:
        assert session.get(User, 'unit-user').avatar_object_key == (key if replace_existing else None)
        assert not list(session.scalars(select(OutboxEvent)))
    assert remote.exists(key) and local.exists(key)
    assert remote.get(upload.object_key) == content


def test_cleanup_worker_retry_rejects_current_pointer(factory, tmp_path):
    from tasks.avatar_cleanup import AvatarCleanupTask
    service, storage, transport, remote, local, key = components(factory, tmp_path)
    transport.failure = client_error('AccessDenied', 403)
    with pytest.raises(AppError):
        service.delete_avatar('unit-user', idempotency_key='delete-1', trace_id='unit', source_ip=None)
    message = cleanup_event(factory)
    worker = AvatarCleanupTask(factory, storage=storage)
    with pytest.raises(AppError):
        worker(message)
    transport.failure = None
    with factory.begin() as session:
        session.get(User, 'unit-user').avatar_object_key = key
    worker(message)
    assert remote.exists(key) and local.exists(key)
    with factory.begin() as session:
        session.get(User, 'unit-user').avatar_object_key = None
    worker(message)
    assert not remote.exists(key) and not local.exists(key)


@pytest.mark.asyncio
async def test_retired_signed_avatar_is_denied_during_storage_outage(factory, tmp_path):
    service, storage, transport, _, _, key = components(factory, tmp_path)
    url = storage.signed_read_url(key, 300)
    settings = Settings(_env_file=None, environment='test',
        jwt_secret='unit-jwt-secret-at-least-thirty-two-bytes')
    app = create_app(settings, session_factory=factory, avatar_storage=storage)
    transport.failure = client_error('AccessDenied', 403)
    with pytest.raises(AppError):
        service.delete_avatar('unit-user', idempotency_key='delete-1', trace_id='unit', source_ip=None)
    parsed = urlparse(url)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='https://example.invalid') as client:
        response = await client.get(parsed.path + '?' + parsed.query)
    assert response.status_code == 404, 'retired URLs must not reach unavailable object storage'
