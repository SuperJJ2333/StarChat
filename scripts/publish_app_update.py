"""发布 app 更新设置（客户端更新弹窗数据源）。

在服务器 business-api 容器内执行（scripts/release_ci.ps1 与
scripts/server_pull_release.sh 下行拉取路径共用；scripts/release.ps1
内嵌同源脚本，行为契约一致：BEFORE/PUBLISH/LATEST 三行输出 +
PUBLISH_RESULT PASS/FAIL）。

环境变量（全部必填，缺一项 fail-fast）：
  RELEASE_VERSION      — X.Y.Z
  RELEASE_BUILD        — versionCode 基数（pubspec +N）
  APK_URL              — 更新弹窗下载地址（arm64 包）
  NOTES_FILE           — 更新文案 UTF-8 文本文件路径（用户可见）
可选：
  MIN_SUPPORTED_BUILD  — 低于此 build 强制更新（默认 3）
  IDEMPOTENCY_KEY      — 幂等键（默认 app-update-publish-<版本>-<UTC日期>）

红线：本脚本只写 app_update 设置（notes/apk_url/版本号），不触碰任何
其他业务数据；幂等键防重复发布。
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

RELEASE_VERSION = os.environ["RELEASE_VERSION"]
RELEASE_BUILD = int(os.environ["RELEASE_BUILD"])
APK_URL = os.environ["APK_URL"]
NOTES_FILE = os.environ["NOTES_FILE"]
MIN_SUPPORTED_BUILD = int(os.environ.get("MIN_SUPPORTED_BUILD", "3"))
IDEMPOTENCY_KEY = os.environ.get(
    "IDEMPOTENCY_KEY",
    f"app-update-publish-{RELEASE_VERSION}"
    f"-{datetime.now(timezone.utc):%Y%m%d}",
)

with open(NOTES_FILE, encoding="utf-8") as handle:
    NOTES = handle.read().strip()
assert NOTES, "更新文案不得为空"

settings = Settings(_env_file=None, environment="production")
engine = create_engine(os.environ["BUSINESS_DATABASE_URL"])
factory = create_session_factory(engine)
now = datetime.now(timezone.utc)
with factory() as session:
    row = session.execute(text(
        "select u.id, d.id as device_id, f.id as family_id from users u "
        "join user_roles r on r.user_id = u.id and r.role_code = 'SUPER_ADMIN' "
        "join identity_devices d on d.user_id = u.id and d.revoked_at is null "
        "join refresh_token_families f on f.device_id = d.id and f.revoked_at is null "
        "where u.username = 'liuhetong_admin' and u.status = 'ACTIVE' limit 1"
    )).first()
    assert row, "no super-admin session"
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
    req = urllib.request.Request(
        "http://127.0.0.1:8082" + path,
        data=json.dumps(payload).encode() if payload else None,
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


_, before = call("GET", "/api/v1/admin/app-update-settings")
print("BEFORE", json.dumps(before, ensure_ascii=False))
status, published = call(
    "PUT",
    "/api/v1/admin/app-update-settings",
    {
        "latest_version": RELEASE_VERSION,
        "latest_build": RELEASE_BUILD,
        "min_supported_build": MIN_SUPPORTED_BUILD,
        "notes": NOTES,
        "apk_url": APK_URL,
    },
)
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
