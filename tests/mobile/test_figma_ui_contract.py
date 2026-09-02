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
    assert "title: '畅聊 ChatFlow'" in main
    assert 'android:label="畅聊 ChatFlow"' in android_manifest
    assert "<string>畅聊 ChatFlow</string>" in ios_info
    assert "final class LiuhetongApp" in main
    assert "name: liuhetong_mobile" in pubspec
    assert "description: 畅聊 ChatFlow Android/iOS Flutter client" in pubspec


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
    verification = read(
        "apps/mobile_flutter/lib/features/auth/verification_page.dart"
    )

    assert "final class AuthSurfaceCard" in components
    assert "final class AuthBrandMark" in components
    assert "final class AuthTextField" in components
    assert "final class AuthAgreementRow" in components
    assert "final class AuthInlineRegisterLink" in components
    assert "SvgPicture.asset(" in components
    assert "assets/branding/liuhetong_logo.svg" in components
    assert "assets/branding/launch_logo.svg" not in components
    assert "Key('auth-surface-card')" in components
    assert "Key('auth-brand-logo')" in components
    assert "Key('auth-agreement-checkbox')" in components
    assert "Key('auth-user-agreement-link')" in components
    assert "Key('auth-privacy-policy-link')" in components
    assert "Key('auth-register-link')" in components
    assert "Key('auth-login-form')" in login
    assert "Key('auth-registration-form')" in registration
    assert "AuthSurfaceCard(" in login
    assert "AuthSurfaceCard(" in registration
    assert "AuthBrandMark(" in verification
    assert "AuthAgreementRow(" in login
    assert "AuthInlineRegisterLink(" in login
    assert "使用用户名或邮箱登录" in login
    assert "创建畅聊账号" in registration
    assert "还没有账号？" in components
    assert "立刻注册" in components


def test_auth_tokens_match_the_393px_figma_contract():
    tokens = read(
        "apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart"
    )

    assert "screenWidth = 393.0" in tokens
    assert "controlHeight = 48.0" in tokens
    assert "minimumTouchTarget = 44.0" in tokens
    assert "authCard = 12.0" in tokens
    assert "authControl = 14.0" in tokens


def test_messaging_and_call_surfaces_follow_the_figma_component_contract():
    conversation = read(
        "apps/mobile_flutter/lib/ui/components/conversation_list_tile.dart"
    )
    composer = read(
        "apps/mobile_flutter/lib/ui/chat/chat_composer_bar.dart"
    )
    call_control = read(
        "apps/mobile_flutter/lib/ui/components/call_control_button.dart"
    )
    matrix_home = read(
        "apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart"
    )
    # 会话页（RoomPage）承载聊天输入与时间线（自 matrix_home_page 拆分）。
    room_page = read(
        "apps/mobile_flutter/lib/features/matrix/room_page.dart"
    )
    call_page = read(
        "apps/mobile_flutter/lib/features/matrix/call_page.dart"
    )

    assert "final class ConversationListTile" in conversation
    assert "key: ValueKey<String>('conversation-" in matrix_home
    assert "final class ChatComposerBar" in composer
    for key in (
        "composer-voice",
        "composer-input",
        "composer-emoji",
        "composer-more",
        "composer-send",
    ):
        assert f"Key('{key}')" in composer
    assert "final class CallControlButton" in call_control
    assert "ConversationListTile(" in matrix_home
    assert "ChatComposerBar(" in room_page
    assert "RoomTimelineController" in room_page
    assert "CallControlButton(" in call_page
    assert "widget.controller.toggleMute" in call_page
    assert "widget.controller.toggleSpeaker" in call_page
    assert "widget.controller.hangup" in call_page


def test_messaging_tokens_and_semantic_icons_cover_figma_nodes():
    tokens = read(
        "apps/mobile_flutter/lib/ui/foundation/wechat_tokens.dart"
    )
    icons = read(
        "apps/mobile_flutter/lib/ui/foundation/changliao_icons.dart"
    )

    for token in (
        "conversationTileHeight = 72.0",
        "conversationAvatar = 48.0",
        "composerMinHeight = 56.0",
        "callControl = 72.0",
    ):
        assert token in tokens
    for name in (
        "more",
        "attachment",
        "muted",
        "speaker",
        "hangup",
        "switchCamera",
        "close",
    ):
        assert f"static const IconData {name}" in icons


def test_discovery_and_profile_use_the_single_real_icon_bottom_navigation():
    app_home = read("apps/mobile_flutter/lib/app_home.dart")
    discovery = read(
        "apps/mobile_flutter/lib/features/discovery/discovery_page.dart"
    )
    profile = read(
        "apps/mobile_flutter/lib/features/profile/profile_page.dart"
    )

    assert app_home.count("CupertinoTabBar(") == 1
    assert "CupertinoTabScaffold(" in app_home
    assert "CupertinoTabBar(" not in discovery
    assert "CupertinoTabBar(" not in profile
    for placeholder in ("'●'", "'◇'", "'▣'"):
        assert placeholder not in app_home + discovery + profile
    for name in ("messages", "contacts", "discover", "me"):
        assert f"Icon(ChangliaoIcons.{name})" in app_home


def test_profile_home_matches_figma_60_profile_information_architecture():
    profile = read(
        "apps/mobile_flutter/lib/features/profile/profile_page.dart"
    )

    assert "height: 126" in profile
    assert "width: 72" in profile
    assert "height: 72" in profile
    for label in ("朋友圈", "点钻", "钱包", "设置"):
        assert f"label: '{label}'" in profile
    assert "key: const Key('profile-identity-card')" in profile
    assert "onMoments" in profile


def test_theme_is_persistent_and_only_resolved_at_the_app_root():
    main = read("apps/mobile_flutter/lib/main.dart")
    controller = read(
        "apps/mobile_flutter/lib/ui/theme/theme_controller.dart"
    )
    messages = read(
        "apps/mobile_flutter/lib/features/matrix/matrix_home_page.dart"
    )

    assert "SharedPreferencesThemePreferenceStore" in main
    assert "await themeController.load()" in main
    assert "ThemePreference.system" in controller
    assert "ThemePreference.light" in controller
    assert "ThemePreference.dark" in controller
    assert "key: const Key('messages-appearance')" in messages
    feature_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (FLUTTER_LIB / "features").rglob("*.dart")
    )
    assert "MediaQuery.platformBrightnessOf" not in feature_sources
