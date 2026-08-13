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

@pytest.mark.asyncio
async def test_media_upload_rejects_oversize_and_creates_scan_session():
    engine=create_engine('sqlite+pysqlite:///:memory:',connect_args={'check_same_thread':False},poolclass=StaticPool);Base.metadata.create_all(engine);factory=create_session_factory(engine);now=datetime.now(timezone.utc)
    with factory.begin() as s:s.add(User(id='u',username='u',username_normalized='u',email='u@x',email_normalized='u@x',password_hash='x',status=AccountStatus.ACTIVE,created_at=now,updated_at=now))
    settings=Settings(_env_file=None,environment='test',jwt_secret='x'*32);token=jwt.encode({'sub':'u','iss':settings.jwt_issuer,'iat':int(now.timestamp()),'exp':int((now+timedelta(minutes=5)).timestamp())},settings.jwt_secret,algorithm='HS256');auth={'Authorization':f'Bearer {token}','Idempotency-Key':'media-1'}
    async with AsyncClient(transport=ASGITransport(app=create_app(settings,session_factory=factory)),base_url='http://test') as c:
        bad=await c.post('/api/v1/moments/media/uploads',headers=auth,json={'file_name':'x.jpg','mime_type':'image/jpeg','byte_size':21*1024*1024});assert bad.status_code==422
        ok=await c.post('/api/v1/moments/media/uploads',headers=auth,json={'file_name':'x.jpg','mime_type':'image/jpeg','byte_size':1024});assert ok.status_code==201
        complete=await c.post(f"/api/v1/moments/media/uploads/{ok.json()['id']}/complete",headers={**auth,'Idempotency-Key':'complete'});assert complete.json()['status']=='SCANNING'
