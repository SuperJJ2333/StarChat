from pathlib import Path


ROOT = Path(__file__).parents[2]
FLUTTER_LIB = ROOT / "apps/mobile_flutter/lib"


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_visible_flutter_brand_uses_changliao_and_internal_identifiers_remain():
    sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in FLUTTER_LIB.rglob("*.dart")
    )
    main = read("apps/mobile_flutter/lib/main.dart")
    pubspec = read("apps/mobile_flutter/pubspec.yaml")
    android_manifest = read(
        "apps/mobile_flutter/android/app/src/main/AndroidManifest.xml"
    )
    ios_info = read("apps/mobile_flutter/ios/Runner/Info.plist")

    assert "六合通" not in sources
    assert "title: '畅聊'" in main
    assert 'android:label="畅聊"' in android_manifest
    assert "<string>畅聊</string>" in ios_info
    assert "final class LiuhetongApp" in main
    assert "name: liuhetong_mobile" in pubspec
    assert "description: 畅聊 Android/iOS Flutter client" in pubspec


def test_semantic_icon_registry_contains_figma_navigation_and_call_icons():
    icons = read(
        "apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart"
    )

    for name in (
        "messages",
        "contacts",
        "discover",
        "me",
        "voiceCall",
        "videoCall",
    ):
        assert f"static const IconData {name}" in icons
    assert icons.count("CupertinoIcons.") >= 12


def test_app_shell_consumes_semantic_navigation_icons():
    app_home = read("apps/mobile_flutter/lib/app_home.dart")

    assert "ui/foundation/changliao_icons.dart" in app_home
    for name in ("messages", "contacts", "discover", "me"):
        assert f"Icon(ChangliaoIcons.{name})" in app_home
        assert f"Icon(ChangliaoIcons.{name}Filled)" in app_home


def test_auth_pages_share_the_figma_surface_components_and_stable_keys():
    components = read(
        "apps/mobile_flutter/lib/ui/components/auth_surface_card.dart"
    )
    login = read("apps/mobile_flutter/lib/features/auth/login_page.dart")
    registration = read(
        "apps/mobile_flutter/lib/features/auth/registration_page.dart"
    )

    assert "final class AuthSurfaceCard" in components
    assert "final class AuthBrandMark" in components
    assert "final class AuthTextField" in components
    assert "Key('auth-surface-card')" in components
    assert "Key('auth-login-form')" in login
    assert "Key('auth-registration-form')" in registration
    assert "AuthSurfaceCard(" in login
    assert "AuthSurfaceCard(" in registration
    assert "使用用户名或邮箱登录" in login
    assert "创建畅聊账号" in registration


def test_auth_tokens_match_the_393px_figma_contract():
    tokens = read(
        "apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart"
    )

    assert "screenWidth = 393.0" in tokens
    assert "controlHeight = 48.0" in tokens
    assert "minimumTouchTarget = 44.0" in tokens
    assert "authCard = 12.0" in tokens
    assert "authControl = 14.0" in tokens
