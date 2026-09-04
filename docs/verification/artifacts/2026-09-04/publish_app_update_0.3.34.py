"""发布 0.3.34+37 应用更新设置。

内容：个推在线推送通道（杀进程后仍可收到新消息/来电通知，通知仅显示
通用文案，端到端加密内容只在设备本地解密）+ 朋友圈删除 + 扫一扫入口 +
通话接通稳定性与质量优化 + 相册/视频发送优化 + 生产 TURN 修复。

用法：
  docker exec -i starchat-business-api-1 python - < publish_app_update_0.3.34.py
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

RELEASE_VERSION = "0.3.34"
RELEASE_BUILD = 2037
MIN_SUPPORTED_BUILD = 3
IDEMPOTENCY_KEY = "app-update-publish-0.3.34-20260904"
APK_URL = f"https://www.liuhetong888.com/downloads/ChatFlow-{RELEASE_VERSION}-arm64.apk"
NOTES = (
    "0.3.34 更新：新增在线推送通道——应用被系统清理后也能收到新消息和"
    "来电提醒（通知仅显示通用提示，聊天内容始终端到端加密）；朋友圈支持"
    "删除自己的动态；消息页加号新增扫一扫；显著提升通话接通率与慢速网络"
    "下的稳定性，新增通话质量诊断；相册打开更快、视频发送显示转码/加密/"
    "上传进度；修复部分网络下通话无法接通的问题。"
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
