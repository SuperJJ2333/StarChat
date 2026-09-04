"""原生 CallService 层合同（防静默弱化）。"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call"
MANIFEST = ROOT / "apps/mobile_flutter/android/app/src/main/AndroidManifest.xml"
APP_HOME = ROOT / "apps/mobile_flutter/lib/app_home.dart"


def test_native_call_layer_files_exist():
    for name in ("IncomingCallReceiver.kt", "CallForegroundService.kt",
                 "CallNotificationManager.kt", "CallBridge.kt"):
        assert (KOTLIN / name).exists(), f"缺少 {name}"


def test_notification_uses_callstyle_and_calls_ring():
    nm = (KOTLIN / "CallNotificationManager.kt").read_text(encoding="utf-8")
    assert "Notification.CallStyle.forIncomingCall" in nm
    assert '"calls_ring"' in nm
    assert "IMPORTANCE_HIGH" in nm
    assert "CATEGORY_CALL" in nm
    assert "chatflow_ringtone" in nm
    # 通知 ID 与 Flutter 侧来电通知一致（互替不叠加）
    assert "notificationId = 41001" in nm
    # CallStyle 前置：MANAGE_OWN_CALLS + PhoneAccount
    assert "MANAGE_OWN_CALLS" in nm
    assert "registerPhoneAccount" in nm


def test_service_and_receiver_wiring():
    svc = (KOTLIN / "CallForegroundService.kt").read_text(encoding="utf-8")
    assert "FOREGROUND_SERVICE_TYPE_PHONE_CALL" in svc
    assert "START_NOT_STICKY" in svc
    rcv = (KOTLIN / "IncomingCallReceiver.kt").read_text(encoding="utf-8")
    assert "actionAnswer" in rcv and "actionReject" in rcv
    bridge = (KOTLIN / "CallBridge.kt").read_text(encoding="utf-8")
    assert 'channelName = "chatflow/call"' in bridge
    assert "openIncomingCall" in bridge and "rejectIncomingCall" in bridge


def test_manifest_registers_native_call_components():
    raw = MANIFEST.read_text(encoding="utf-8")
    assert "MANAGE_OWN_CALLS" in raw
    assert "FOREGROUND_SERVICE_PHONE_CALL" in raw
    assert ".call.CallForegroundService" in raw
    assert 'foregroundServiceType="phoneCall"' in raw
    assert ".call.IncomingCallReceiver" in raw
    assert ".call.ChatFlowConnectionService" in raw


def test_getui_transmission_entry_starts_service():
    entry = (ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/"
             "com/liuhetong/mobile/ChatFlowGetuiIntentService.kt").read_text(encoding="utf-8")
    # 透传统一经 GetuiReceiver → PushEventDispatcher 分发
    assert "GetuiReceiver.onTransmit" in entry
    receiver = (KOTLIN.parent / "push/GetuiReceiver.kt").read_text(encoding="utf-8")
    assert "PushEventDispatcher.dispatch" in receiver


def test_flutter_handles_native_call_actions():
    raw = APP_HOME.read_text(encoding="utf-8")
    assert "MethodChannel('chatflow/call')" in raw
    assert "'openIncomingCall'" in raw
    assert "'rejectIncomingCall'" in raw
    assert "calls.accept()" in raw
    assert "calls.reject()" in raw
    # 接管后停原生层
    assert "invokeMethod('dismiss')" in raw
    # 红线：WebRTC/CallSession 不落原生（call/ 目录不得 import/调用 webrtc）
    import re as _re

    for f in KOTLIN.glob("*.kt"):
        source = f.read_text(encoding="utf-8")
        refs = [line for line in source.splitlines()
                if _re.search(r'(import\s+\S*webrtc|webrtc\s*\.)', line, _re.I)]
        assert not refs, f"{f.name} 不得引用 webrtc（媒体留在 Flutter）：{refs}"


def test_push_event_dispatcher_routes_three_types():
    base = ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/push"
    receiver = (base / "GetuiReceiver.kt").read_text(encoding="utf-8")
    dispatcher = (base / "GetuiReceiver.kt").read_text(encoding="utf-8")
    for t in ("message", "friend_request", "call"):
        assert f'"{t}"' in receiver, f"缺少事件类型 {t}"
    # call → CallForegroundService（绝不用普通通知展示来电）
    assert "CallForegroundService.start" in dispatcher
    assert "notifyFlutter" in dispatcher
    # Flutter 桥通道一致
    kotlin_bridge = (base / "NativePushBridge.kt").read_text(encoding="utf-8")
    assert 'chatflow/push' in kotlin_bridge
    dart_bridge = (ROOT / "apps/mobile_flutter/lib/features/push/native_push_bridge.dart").read_text(encoding="utf-8")
    assert "chatflow/push" in dart_bridge
    assert "pushMessage" in dart_bridge and "friendRequest" in dart_bridge
