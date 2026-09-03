"""发布 0.3.30+33 应用更新设置。

内容：后台/锁屏通知三层保活加固（唤醒锁/看门狗/电池优化引导）、
后台来电由系统通知渠道发声（calls_ring）。

用法：
  docker exec -i starchat-business-api-1 python - < publish_app_update_0.3.30.py
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from uuid import uuid4

sys.path.insert(0, "/opt/business-api")

from sqlalchemy import create_engine, text

from app.core.config import Settings
from app.core.database import create_session_factory

RELEASE_VERSION = "0.3.30"
RELEASE_BUILD = 2033
MIN_SUPPORTED_BUILD = 3
IDEMPOTENCY_KEY = "app-update-publish-0.3.30-20260903"
APK_URL = f"https://www.liuhetong888.com/downloads/ChatFlow-{RELEASE_VERSION}-arm64.apk"
NOTES = (
    "0.3.30 更新：后台与锁屏通知深度修复——新增息屏唤醒锁与"
    "自动恢复机制，解决锁屏几分钟后收不到消息通知、提示音与来电"
    "铃声的问题；后台来电改由系统通知直接播放铃声，更稳定；升级后"
    "首次启动会引导开启\"后台消息保障\"（允许忽略电池优化），"
    "小米/红米用户另请在 设置→应用管理→畅聊 开启\"自启动\"并把"
    "省电策略设为\"无限制\"，即可获得与微信一致的后台接收效果。"
)

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
    assert row, "no active super-admin session material found"
    user_id, device_id, family_id = row

import jwt

claims = {
    "sub": user_id,
    "device_id": device_id,
    "family_id": family_id,
    "iss": os.environ.get("BUSINESS_JWT_ISSUER", "liuhetong"),
    "iat": int(now.timestamp()),
    "exp": int(now.timestamp()) + 300,
    "jti": str(uuid4()),
}
token = jwt.encode(claims, os.environ["BUSINESS_JWT_SECRET"], algorithm="HS256")
headers = {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json",
    "Idempotency-Key": IDEMPOTENCY_KEY,
}


def call(method, path, payload=None):
    request = urllib.request.Request(
        "http://127.0.0.1:8082" + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


status, before = call("GET", "/api/v1/admin/app-update-settings")
print("BEFORE", status, json.dumps(before, ensure_ascii=False))

payload = {
    "latest_version": RELEASE_VERSION,
    "latest_build": RELEASE_BUILD,
    "min_supported_build": MIN_SUPPORTED_BUILD,
    "notes": NOTES,
    "apk_url": APK_URL,
}
status, published = call("PUT", "/api/v1/admin/app-update-settings", payload)
print("PUBLISH", status, json.dumps(published, ensure_ascii=False))

status, latest = call("GET", "/api/v1/app-updates/latest")
print("LATEST", status, json.dumps(latest, ensure_ascii=False))

ok = (
    status == 200
    and latest.get("configured")
    and latest.get("latest_version") == RELEASE_VERSION
    and latest.get("latest_build") == RELEASE_BUILD
    and latest.get("apk_url") == APK_URL
)
print("PUBLISH_RESULT", "PASS" if ok else "FAIL")
if not ok:
    raise SystemExit(1)
