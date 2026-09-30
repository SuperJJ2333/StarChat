"""Native security boundary: message UI cannot be a lockscreen activity."""
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
MOBILE = ROOT / "apps/mobile_flutter"
ANDROID = MOBILE / "android/app/src/main"
NS = "{http://schemas.android.com/apk/res/android}"


def test_launcher_cannot_show_above_or_wake_keyguard():
    activities = ET.parse(ANDROID / "AndroidManifest.xml").getroot().findall(
        "./application/activity"
    )
    main = next(a for a in activities if a.get(NS + "name") == ".MainActivity")
    assert main.get(NS + "showWhenLocked") == "false"
    assert main.get(NS + "turnScreenOn") == "false"
    call = next(a for a in activities if a.get(NS + "name") == ".call.CallActivity")
    assert call.get(NS + "showWhenLocked") == "true"
    assert call.get(NS + "turnScreenOn") == "true"


def test_call_presentation_does_not_automatically_dismiss_keyguard():
    source = (ANDROID / "kotlin/com/liuhetong/mobile/call/CallActivity.kt").read_text(
        encoding="utf-8"
    )
    assert "requestDismissKeyguard(" not in source
    assert "FLAG_DISMISS_KEYGUARD" not in source
    assert "setShowWhenLocked(true)" in source
    assert "setTurnScreenOn(true)" in source


def test_native_apns_delivery_requires_active_ui():
    source = (MOBILE / "ios/Runner/AppDelegate.swift").read_text(encoding="utf-8")
    delivery = source.split("private func deliverPendingTap()", 1)[1].split(
        "// MARK:", 1
    )[0]
    assert "IOSMessageNavigationGate.allows(" in delivery
    assert "UIApplication.shared.applicationState" in delivery
    assert "UIApplication.shared.connectedScenes.map" in delivery
    gate = source.split("enum IOSMessageNavigationGate", 1)[1].split("@main", 1)[0]
    assert "applicationState == .active" in gate
    assert "$0 == .foregroundActive" in gate


def test_ios_inactive_scene_disables_touch_before_super_callback():
    source = (MOBILE / "ios/Runner/SceneDelegate.swift").read_text(encoding="utf-8")
    assert "override func sceneWillResignActive" in source
    inactive = source.split("override func sceneWillResignActive", 1)[1].split(
        "\n  }", 1
    )[0]
    assert inactive.index("isUserInteractionEnabled = false") < inactive.index(
        "super.sceneWillResignActive"
    )
    active = source.split("override func sceneDidBecomeActive", 1)[1].split(
        "\n  }", 1
    )[0]
    assert "isUserInteractionEnabled = true" in active
    assert "resumeMessageNotificationRouting()" in active
