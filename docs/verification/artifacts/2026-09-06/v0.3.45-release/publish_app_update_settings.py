"""One-shot publisher for the 0.3.45 app-update settings.

Runs INSIDE the starchat-business-api-1 container (workdir /opt/business-api)
so it uses the app's own SettingService: same key/value rows and the same
settings.update audit event (before/after values) as the admin API, without
needing an admin JWT. Every write carries actor + trace identity.

Usage:
    docker exec -i -w /opt/business-api starchat-business-api-1 \
        python3 - < publish_app_update_settings.py
"""

from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.modules.settings.service import (
    APP_APK_URL_KEY,
    APP_LATEST_BUILD_KEY,
    APP_LATEST_VERSION_KEY,
    APP_MIN_SUPPORTED_BUILD_KEY,
    APP_UPDATE_NOTES_KEY,
    APP_UPDATE_SETTING_KEYS,
    SettingService,
)

ACTOR_ID = "release-deploy"
TRACE_ID = "release-0.3.45-build48"

NOTES = """v0.3.45 更新
新增：聊天记录搜索（关键词、群成员、日期月历、图片视频、文件、链接分类，高亮显示，滚动加载）；群成员列表拼音排序与搜索；视频预览图会话缓存；GIF 自动播放；图片按实际比例显示。
优化：@提及输入、选择、发送全链路；后台来电恢复与锁屏全屏通知；未读@逐条跳转定位。
修复：多项性能与稳定性问题。"""

PAYLOAD = {
    APP_LATEST_VERSION_KEY: "0.3.45",
    APP_LATEST_BUILD_KEY: "48",
    APP_MIN_SUPPORTED_BUILD_KEY: "3",
    APP_UPDATE_NOTES_KEY: NOTES,
    APP_APK_URL_KEY: (
        "https://www.liuhetong888.com/downloads/ChatFlow-0.3.45-arm64.apk"
    ),
}

EXPECTED_APK_SHA256 = (
    "f2519bd919c4b6fcb060384ab723576a75ff995c0e931261fb6ae00920534007"
)


def main() -> int:
    session_factory = create_session_factory(create_engine(Settings()))
    service = SettingService(session_factory)

    print("BEFORE:")
    for key in APP_UPDATE_SETTING_KEYS:
        print(f"  {key} = {service.get(key)!r}")

    for key, value in PAYLOAD.items():
        service.set(key, value, actor_id=ACTOR_ID, trace_id=TRACE_ID)

    print("AFTER:")
    failures = []
    for key, expected in PAYLOAD.items():
        actual = service.get(key)
        status = "OK" if actual == expected else "MISMATCH"
        if status != "OK":
            failures.append(key)
        print(f"  [{status}] {key} = {actual!r}")

    if failures:
        print(f"PUBLISH_RESULT FAIL keys={failures}")
        return 1
    print("PUBLISH_RESULT PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
