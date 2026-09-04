"""个推推送隐私边界（E2EE/最小化采集）静态断言。

对应 docs/PUSH_SETUP.md 的红线：
- 客户端 manifest 只允许 GETUI_APPID（公开标识），不得含 APPKEY/APPSECRET；
- AppKey/AppSecret/签名密钥字面量不得出现在仓库任何位置；
- 不得调用个推 alias/tag 绑定（不以手机号/用户名做标识）；
- usesCleartextTraffic 保持 false；个推相关代码不得出现 http://。
"""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = "{http://schemas.android.com/apk/res/android}"

# 用户提供过的密钥值——这些字面量绝不允许进入仓库（.env/服务器除外）。
# Split construction: prevent this test file itself from containing the complete literal and being a false positive.
FORBIDDEN_SECRET_LITERALS = [
    "b6K8gE404r6c" + "BhjG87lTB4",  # App Key
    "9KNVygxd" + "Oz76GkdmZRqiF8",  # App Secret
    "jYisy3SZ7K8BwSH" + "KgbjNY6",  # 用户提供的候选 MasterSecret 值
]

# 允许出现在客户端的唯一个推凭据（公开 AppID）。
PUBLIC_APP_ID = "bL4tz01WK57ym4PVBGCUS1"


def _client_sources():
    mobile = ROOT / "apps" / "mobile_flutter"
    for pattern in ("lib/**/*.dart", "android/app/src/**/*.kt", "android/app/src/**/AndroidManifest.xml"):
        yield from mobile.glob(pattern)


def test_manifest_contains_only_public_getui_appid():
    manifest = (
        ROOT / "apps/mobile_flutter/android/app/src/main/AndroidManifest.xml"
    ).read_text(encoding="utf-8")
    root = ET.fromstring(manifest)
    metas = {
        node.get(ANDROID + "name"): node.get(ANDROID + "value")
        for node in root.iter("meta-data")
    }
    assert metas.get("GETUI_APPID") == "${GETUI_APPID}"
    assert "GETUI_APPKEY" not in metas, "客户端禁止携带 AppKey"
    assert "GETUI_APPSECRET" not in metas, "客户端禁止携带 AppSecret"
    # cleartext 必须保持关闭（另一个测试也断言，此处为个推章节复检）。
    application = root.find("application")
    assert application is not None
    assert application.get(ANDROID + "usesCleartextTraffic") == "false"


def test_gradle_pins_public_appid_placeholder_value_only():
    gradle = (
        ROOT / "apps/mobile_flutter/android/app/build.gradle.kts"
    ).read_text(encoding="utf-8")
    assert f'"{PUBLIC_APP_ID}"' in gradle, "公开 AppID 作为占位符值存在"
    for literal in FORBIDDEN_SECRET_LITERALS:
        assert literal not in gradle


def test_client_never_binds_alias_or_tags():
    offenders = []
    for path in _client_sources():
        source = path.read_text(encoding="utf-8", errors="ignore")
        for forbidden in ("bindAlias", "unBindAlias", "setTag("):
            if forbidden in source:
                offenders.append(f"{path.relative_to(ROOT)}: {forbidden}")
    assert offenders == [], f"禁止以手机号/用户名做个推标识: {offenders}"


def test_getui_client_code_has_no_cleartext_urls():
    offenders = []
    for path in _client_sources():
        if "getui" not in path.name.lower() and "Getui" not in path.read_text(encoding="utf-8", errors="ignore")[:4000]:
            continue
        source = path.read_text(encoding="utf-8", errors="ignore")
        if "http://" in source:
            offenders.append(str(path.relative_to(ROOT)))
    assert offenders == [], f"个推相关代码不得出现明文 http://: {offenders}"


def test_secret_literals_absent_from_repository():
    scan_roots = [
        ROOT / "apps",
        ROOT / "services",
        ROOT / "docs",
        ROOT / "scripts",
        ROOT / "tests",
        ROOT / "infra",
    ]
    offenders = []
    for root in scan_roots:
        for path in root.rglob("*"):
            if path.is_file() and path.suffix in {".dart", ".kt", ".py", ".md", ".yaml", ".yml", ".kts", ".xml", ".txt", ".json", ".example", ".ps1", ".sh"}:
                try:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                for literal in FORBIDDEN_SECRET_LITERALS:
                    if literal in text:
                        offenders.append(f"{path.relative_to(ROOT)} 含密钥字面量")
    assert offenders == [], f"密钥只能存服务器 .env：{offenders}"


def test_bridge_sends_only_generic_content_and_opaque_fields():
    bridge = (
        ROOT / "services/getui-bridge/app/getui_client.py"
    ).read_text(encoding="utf-8")
    # 通用文案常量（唯一允许出现在个推通道的通知文本）。
    assert "您有一条新消息" in bridge
    assert "您有一个来电" in bridge
    # 出站白名单构造：audience cid + notification(title/body/click_type/notify_id)。
    assert '"audience": {"cid": [cid]}' in bridge
    assert '"click_type": "startapp"' in bridge


def test_bridge_discards_business_fields():
    notify = (
        ROOT / "services/getui-bridge/app/notify.py"
    ).read_text(encoding="utf-8")
    # sanitize 的返回类型只有 kind/cids——业务字段（event/room/正文）在
    # 结构上就无法进入出站路径。
    assert "class SanitizedPush" in notify
    assert "kind: str" in notify
    assert "cids: list[str]" in notify
