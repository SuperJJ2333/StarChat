from datetime import datetime, timedelta, timezone
import jwt, pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool
from app.core.config import Settings
from app.core.database import Base, create_session_factory
from app.main import create_app
from app.modules.identity.enums import AccountStatus
from app.modules.identity.models import User
from app.modules.moments.models import MomentsPreference


class MemoryMomentStorage:
    def __init__(self):
        self.objects = {}

    def put(self, object_key, content):
        self.objects[object_key] = content

    def signed_read_url(self, object_key, expires_in):
        return f'https://media.example.test/{object_key}?signed=1'

@pytest.mark.asyncio
async def test_media_upload_rejects_oversize_and_creates_scan_session():
    engine=create_engine('sqlite+pysqlite:///:memory:',connect_args={'check_same_thread':False},poolclass=StaticPool);Base.metadata.create_all(engine);factory=create_session_factory(engine);now=datetime.now(timezone.utc)
    with factory.begin() as s:s.add(User(id='u',username='u',username_normalized='u',email='u@x',email_normalized='u@x',password_hash='x',status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
    settings=Settings(_env_file=None,environment='test',jwt_secret='x'*32);token=jwt.encode({'sub':'u','iss':settings.jwt_issuer,'iat':int(now.timestamp()),'exp':int((now+timedelta(minutes=5)).timestamp())},settings.jwt_secret,algorithm='HS256');auth={'Authorization':f'Bearer {token}','Idempotency-Key':'media-1'}
    async with AsyncClient(transport=ASGITransport(app=create_app(settings,session_factory=factory)),base_url='http://test') as c:
        bad=await c.post('/api/v1/moments/media/uploads',headers=auth,json={'file_name':'x.jpg','mime_type':'image/jpeg','byte_size':21*1024*1024});assert bad.status_code==422
        ok=await c.post('/api/v1/moments/media/uploads',headers=auth,json={'file_name':'x.jpg','mime_type':'image/jpeg','byte_size':1024});assert ok.status_code==201
        complete=await c.post(f"/api/v1/moments/media/uploads/{ok.json()['id']}/complete",headers={**auth,'Idempotency-Key':'complete'});assert complete.json()['status']=='SCANNING'


@pytest.mark.asyncio
async def test_cover_upload_persists_object_key_and_rejects_moment_media():
    engine = create_engine(
        'sqlite+pysqlite:///:memory:',
        connect_args={'check_same_thread': False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    factory = create_session_factory(engine)
    now = datetime.now(timezone.utc)
    with factory.begin() as session:
        session.add(User(
            id='u', username='user_id', username_normalized='user_id',
            nickname='用户', email='u@x', email_normalized='u@x',
            password_hash='x', status=AccountStatus.ACTIVE,
            created_at=now, updated_at=now,
        ))
    settings = Settings(
        _env_file=None, environment='test', jwt_secret='x' * 32
    )
    token = jwt.encode(
        {
            'sub': 'u', 'iss': settings.jwt_issuer,
            'iat': int(now.timestamp()),
            'exp': int((now + timedelta(minutes=5)).timestamp()),
        },
        settings.jwt_secret,
        algorithm='HS256',
    )
    authorization = {'Authorization': f'Bearer {token}'}
    storage = MemoryMomentStorage()
    app = create_app(
        settings, session_factory=factory, avatar_storage=storage
    )
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url='http://test'
    ) as client:
        ordinary = await client.post(
            '/api/v1/moments/media/uploads',
            headers={**authorization, 'Idempotency-Key': 'ordinary'},
            json={
                'file_name': 'ordinary.jpg',
                'mime_type': 'image/jpeg',
                'byte_size': 3,
            },
        )
        cover = await client.post(
            '/api/v1/moments/cover/uploads',
            headers={**authorization, 'Idempotency-Key': 'cover'},
            json={
                'file_name': 'cover.jpg',
                'mime_type': 'image/jpeg',
                'byte_size': 3,
            },
        )
        assert cover.status_code == 201
        upload_id = cover.json()['id']
        uploaded = await client.put(
            f'/api/v1/moments/cover/uploads/{upload_id}/content',
            headers={**authorization, 'Content-Type': 'image/jpeg'},
            content=b'abc',
        )
        assert uploaded.status_code == 204
        completed = await client.post(
            f'/api/v1/moments/cover/uploads/{upload_id}/complete',
            headers={**authorization, 'Idempotency-Key': 'cover-complete'},
        )
        assert completed.json()['status'] == 'COMPLETED'
        rejected = await client.put(
            '/api/v1/moments/cover',
            headers={**authorization, 'Idempotency-Key': 'bad-cover-set'},
            json={'upload_id': ordinary.json()['id']},
        )
        assert rejected.status_code == 422
        saved = await client.put(
            '/api/v1/moments/cover',
            headers={**authorization, 'Idempotency-Key': 'cover-set'},
            json={'upload_id': upload_id},
        )
        assert saved.status_code == 200
        assert saved.json()['cover_url'].startswith(
            'https://media.example.test/moments/covers/u/'
        )
    with factory() as session:
        preference = session.get(MomentsPreference, 'u')
        assert preference.cover_object_key.startswith('moments/covers/u/')
        assert preference.cover_url is None
