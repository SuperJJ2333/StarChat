"""发布 0.3.26+29 应用更新设置（latest_build 采用 arm64 清单值 2000+build，
兼容旧客户端构建号比较）（在 starchat-business-api-1 容器内执行）。

用法：
  docker exec -i starchat-business-api-1 python - < publish_app_update_0.3.26.py

依赖容器内已注入的 BUSINESS_DATABASE_URL / BUSINESS_JWT_SECRET。
通过管理端 RBAC 接口写入 app_settings，并以未认证可访问的
/api/v1/app-updates/latest 做端到端确认。
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

RELEASE_VERSION = "0.3.26"
RELEASE_BUILD = 2029
MIN_SUPPORTED_BUILD = 3
IDEMPOTENCY_KEY = "app-update-publish-0.3.26-20260902"
APK_URL = f"https://www.liuhetong888.com/downloads/ChatFlow-{RELEASE_VERSION}-arm64.apk"
NOTES = (
    "0.3.26 版本更新：媒体选择器支持选择视频并显示时长（修复 Android 13+ "
    "只能读取图片的问题）；聊天图片/视频优先加载加密缩略图，点击查看原图，"
    "会话打开更快；聊天记录上滑到顶部自动加载更早消息；长按“拍摄”可录视频，"
    "发送前自动压缩并显示进度；“我”页新增邀请码入口，好友注册填写即建立邀请关系；"
    "长按消息菜单支持本地删除且转发更精准；语音/通话气泡文字颜色统一；"
    "更多面板点击外部自动收起；私聊/群聊好友名称按备注与群昵称优先显示；"
    "修复裁剪头像确认按钮被状态栏遮挡。"
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

status, after = call("GET", "/api/v1/admin/app-update-settings")
print("AFTER", status, json.dumps(after, ensure_ascii=False))

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
