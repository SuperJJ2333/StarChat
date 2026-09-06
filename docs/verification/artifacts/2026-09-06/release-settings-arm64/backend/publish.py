"""Publish verified 0.3.46 using the same validation and transaction as admin API."""
import json
from sqlalchemy import select, func, text
from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.api.admin import AppUpdateSettingsBody
from app.modules.audit.models import AuditEvent
from app.modules.settings.service import (
    SettingService, APP_UPDATE_SETTING_KEYS, APP_LATEST_VERSION_KEY,
    APP_LATEST_BUILD_KEY, APP_MIN_SUPPORTED_BUILD_KEY, APP_UPDATE_NOTES_KEY,
    APP_APK_URL_KEY,
)

factory = create_session_factory(create_engine(Settings()))
service = SettingService(factory)
before = service.get_many(APP_UPDATE_SETTING_KEYS)
notes = """v0.3.46 更新
安装包瘦身：精简不适用于 ARM64 手机的组件，安装包由约 116MB 降至约 72MB，保留聊天、语音视频通话、扫码及消息加密能力。
表情收藏：收藏面板使用缓存和小尺寸预览，减少大图及 GIF 引起的卡顿；再次打开可复用缓存，长按收藏表情可以删除，发送时保留原始表情。
消息与会话：启动后先显示已有消息，后台继续同步；优化从好友资料进入已有会话的速度。
聊天记录：按群成员查找时正常展示头像和消息摘要，多媒体消息显示对应类型；支持关键词、日期、图片与视频、文件和链接分类查找。
朋友圈：发现页显示新增朋友圈数量，查看后更新提醒。
延续修复：优化 GIF 发送与显示、图片完整比例展示、@联系人输入、失败消息重试及聊天记录定位。"""
body = AppUpdateSettingsBody(
    latest_version="0.3.46", latest_build=49,
    min_supported_build=int(before[APP_MIN_SUPPORTED_BUILD_KEY] or "3"),
    notes=notes,
    apk_url="https://www.liuhetong888.com/downloads/ChatFlow-0.3.46-arm64.apk",
)
assert body.min_supported_build <= body.latest_build
payload = {
    APP_LATEST_VERSION_KEY: body.latest_version, APP_LATEST_BUILD_KEY: str(body.latest_build),
    APP_MIN_SUPPORTED_BUILD_KEY: str(body.min_supported_build), APP_UPDATE_NOTES_KEY: body.notes,
    APP_APK_URL_KEY: body.apk_url,
}
assert int(before[APP_LATEST_BUILD_KEY] or "0") <= 49, "Newer release exists; refuse regression"
trace = "release-0.3.46-build49"
if before != payload:
    service.set_many(payload, actor_id="release-deploy", trace_id=trace)
assert service.get_many(APP_UPDATE_SETTING_KEYS) == payload
with factory() as session:
    count = session.scalar(select(func.count()).select_from(AuditEvent).where(AuditEvent.trace_id == trace, AuditEvent.action == "settings.update"))
    column_type = session.scalar(text("SELECT data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='app_settings' AND column_name='value'"))
assert count == 5, count
assert column_type == "text", column_type
print(json.dumps({"status": "PUBLISH_PASS", "version": body.latest_version, "build": body.latest_build, "notes_characters": len(notes), "audit_events": count, "value_column": column_type, "apk_url": body.apk_url}, ensure_ascii=False))
