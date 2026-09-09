from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from sqlalchemy import create_engine, event
from sqlalchemy.pool import StaticPool

from app.main import create_app  # Registers the application model metadata.
from app.core.database import Base, create_session_factory
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.moments.media import MomentMediaService, MomentMediaUpload
from app.modules.moments.models import Moment
from app.modules.moments.service import MomentsService


@pytest.fixture
def media_context():
    engine = create_engine('sqlite+pysqlite:///:memory:', poolclass=StaticPool,
                           connect_args={'check_same_thread': False})
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        for actor in ['alice', 'bob']:
            session.add(User(id=actor, username=actor, username_normalized=actor,
                             email=f'{actor}@example.test', email_normalized=f'{actor}@example.test',
                             password_hash='synthetic', status=AccountStatus.ACTIVE,
                             created_at=now, updated_at=now))
    folder = Path('docs/verification/artifacts/2026-09-09/mobile-parity/stable-media-test')
    folder.mkdir(parents=True, exist_ok=True)
    storage = LocalPrivateObjectStorage(root=str(folder), signing_secret='synthetic-test-only-secret',
                                       public_base_url='https://media.example.test')
    yield factory, storage, MomentMediaService(factory, storage), MomentsService(factory, avatar_storage=storage)
    engine.dispose()


def _uploaded(media, purpose='MOMENT_IMAGE', key='one'):
    row = media.begin('alice', 'image.png', 'image/png', 3, key, purpose=purpose)
    media.put_content('alice', row.id, b'one', 'image/png')
    return media.complete('alice', row.id)


def test_resigning_preserves_deployed_reference_digest_contract(media_context):
    factory, storage, media, service = media_context
    upload = _uploaded(media)
    original = storage.signed_read_url(upload.object_key, 300)
    created = service.create('alice', {'text': 'synthetic', 'visibility': 'PUBLIC',
                                      'image_urls': [original, 'https://external.example/photo?v=one']}, 'post')
    with factory() as session:
        row = session.get(Moment, created.id)
        first = service.dto(session, row, 'alice')
        second = service.dto(session, row, 'alice')
        other = service.dto(session, row, 'bob')
        assert first['image_urls'][0] != second['image_urls'][0]
        assert first['image_cache_keys'][0] == second['image_cache_keys'][0]
        assert first['image_cache_keys'][0] == other['image_cache_keys'][0]  # Client adds account isolation.
        assert first['image_cache_keys'][1] == service._media_cache_key('https://external.example/photo?v=one')
        row.image_urls = [storage.signed_read_url('moments/alice/new-object.png', 300)]
        changed = service.dto(session, row, 'alice')
        assert changed['image_cache_keys'][0] != first['image_cache_keys'][0]
        # The deployed server hashes references; client rejects external/unknown paths.
        row.image_urls = [original.replace('media.example.test', 'foreign.example'),
                          'https://media.example.test/api/v1/profile/avatar/content/invalid']
        unknown = service.dto(session, row, 'alice')
        assert unknown['image_cache_keys'] == [service._media_cache_key(url) for url in row.image_urls]


def test_cover_key_survives_preferences_resign_and_changes_with_new_upload(media_context):
    _, _, media, service = media_context
    upload = _uploaded(media, 'MOMENT_COVER')
    saved = service.set_cover('alice', upload.id, 'cover')
    prefs = service.preferences('alice')
    assert saved['cover_url'] != prefs['cover_url']
    assert saved['cover_cache_key'] == prefs['cover_cache_key']
    other = _uploaded(media, 'MOMENT_COVER', 'two')
    changed = service.set_cover('alice', other.id, 'cover-two')
    assert changed['cover_cache_key'] != saved['cover_cache_key']
    assert service.preferences('bob')['cover_cache_key'] is None


def test_completed_upload_is_idempotent_even_after_upload_window(media_context):
    factory, storage, media, _ = media_context
    uploaded = _uploaded(media)
    assert media.complete('alice', uploaded.id).status == 'COMPLETED'
    with factory.begin() as session:
        session.get(MomentMediaUpload, uploaded.id).expires_at = datetime.now(timezone.utc) - timedelta(days=1)
    assert media.complete('alice', uploaded.id).status == 'COMPLETED'
    assert storage.get(uploaded.object_key) == b'one'


def test_completed_upload_cannot_be_overwritten(media_context):
    _, storage, media, _ = media_context
    uploaded = _uploaded(media)
    with pytest.raises(AppError) as failure:
        media.put_content('alice', uploaded.id, b'two', 'image/png')
    assert failure.value.status_code == 409
    assert storage.get(uploaded.object_key) == b'one'


def test_put_and_complete_lock_the_upload_row(media_context):
    from sqlalchemy.orm import Session
    from sqlalchemy.dialects import postgresql
    _, _, media, _ = media_context
    upload = media.begin('alice', 'lock.png', 'image/png', 3, 'lock')
    statements = []
    def observe(state):
        statements.append(str(state.statement.compile(dialect=postgresql.dialect())))
    event.listen(Session, 'do_orm_execute', observe)
    try:
        media.put_content('alice', upload.id, b'one', 'image/png')
        media.complete('alice', upload.id)
    finally:
        event.remove(Session, 'do_orm_execute', observe)
    selects = [sql for sql in statements if 'FROM moment_media_uploads' in sql]
    assert len(selects) == 2
    assert all('FOR UPDATE' in sql for sql in selects)
