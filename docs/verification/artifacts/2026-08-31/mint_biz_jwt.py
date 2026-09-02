"""输出超管业务 JWT（供 k6 setup 使用）。在业务 API 容器内执行。"""
import os
import sys
from datetime import datetime, timezone
from uuid import uuid4

sys.path.insert(0, "/opt/business-api")

from sqlalchemy import create_engine, text

from app.core.config import Settings
from app.core.database import create_session_factory

settings = Settings(_env_file=None, environment="production")
engine = create_engine(os.environ["BUSINESS_DATABASE_URL"])
factory = create_session_factory(engine)
now = datetime.now(timezone.utc)

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
    if row is None:
        print("no admin session", file=sys.stderr)
        sys.exit(1)
    user_id, device_id, family_id = row

import jwt

claims = {
    "sub": user_id,
    "device_id": device_id,
    "family_id": family_id,
    "iss": os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
    "iat": int(now.timestamp()),
    "exp": int(now.timestamp()) + 7200,
    "jti": str(uuid4()),
}
token = jwt.encode(claims, os.environ["BUSINESS_JWT_SECRET"], algorithm="HS256")
sys.stdout.write("Bearer " + token)
sys.exit(0)
