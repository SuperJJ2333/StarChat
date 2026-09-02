import os
import sys
import time
import json
import urllib.request
import urllib.error

sys.path.insert(0, "/opt/business-api")

from app.core.config import Settings
from app.core.database import create_session_factory
from sqlalchemy import create_engine, text

settings = Settings(_env_file=None, environment="production")
db_url = os.environ["BUSINESS_DATABASE_URL"]
engine = create_engine(db_url)
factory = create_session_factory(engine)

from app.modules.identity.tokens import TokenService

tokens = TokenService(
    factory,
    jwt_secret=os.environ["BUSINESS_JWT_SECRET"],
    jwt_issuer=os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
    require_session_claims=False,
)

from app.modules.identity.enums import RoleCode
from app.modules.identity.models import Device, RefreshTokenFamily, User, UserRole

with factory() as session:
    row = session.execute(
        text(
            "select u.id, d.id as device_id, f.id as family_id "
            "from users u "
            "join user_roles r on r.user_id = u.id and r.role_code = 'SUPER_ADMIN' "
            "join identity_devices d on d.user_id = u.id and d.revoked_at is null "
            "join refresh_token_families f on f.device_id = d.id and f.revoked_at is null "
            "where u.username = 'liuhetong_admin' and u.status = 'ACTIVE' "
            "limit 1"
        )
    ).first()
    assert row, "no active super-admin session material"
    uid, device_id, family_id = row

import jwt
from uuid import uuid4

now = int(time.time())
payload = {
    "sub": uid,
    "device_id": device_id,
    "family_id": family_id,
    "iss": os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
    "iat": now,
    "exp": now + 120,
    "jti": str(uuid4()),
}
token = jwt.encode(payload, os.environ["BUSINESS_JWT_SECRET"], algorithm="HS256")

request = urllib.request.Request(
    "http://127.0.0.1:8082/api/v1/friends/requests",
    headers={"Authorization": "Bearer " + token},
)
try:
    body = json.load(urllib.request.urlopen(request, timeout=10))
    print("FRIEND_REQUESTS STATUS=200 ITEMS=", len(body.get("items", [])))
except urllib.error.HTTPError as error:
    print("FRIEND_REQUESTS STATUS=", error.code)

for query in ("liu", "a1", "zz"):
    request = urllib.request.Request(
        f"http://127.0.0.1:8082/api/v1/users/search?q={query}",
        headers={"Authorization": "Bearer " + token},
    )
    try:
        body = json.load(urllib.request.urlopen(request, timeout=10))
        names = [item["username"] for item in body.get("items", [])]
        print(f"QUERY={query} STATUS=200 ITEMS={len(body.get('items', []))} {names[:5]}")
    except urllib.error.HTTPError as error:
        print(f"QUERY={query} STATUS={error.code}")
