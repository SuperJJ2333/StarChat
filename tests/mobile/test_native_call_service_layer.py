"""原生 CallService 层合同（防静默弱化）。"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call"
MANIFEST = ROOT / "apps/mobile_flutter/android/app/src/main/AndroidManifest.xml"
APP_HOME = ROOT / "apps/mobile_flutter/lib/app_home.dart"
COORDINATOR = ROOT / "apps/mobile_flutter/lib/features/matrix/native_call_coordinator.dart"


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
    # Legacy channel is presentation cleanup only; one native_call action path
    # prevents accepting twice when both old and new bridges are installed.
    legacy = bridge[bridge.index("object CallBridge {"):bridge.index("object NativeCallBridge {")]
    assert 'methodDismiss = "dismiss"' in legacy
    assert "onDismiss()" in legacy
    assert "openIncomingCall" not in legacy and "rejectIncomingCall" not in legacy
    native = bridge[bridge.index("object NativeCallBridge {"):]
    for event in ('eventAccepted = "callAccepted"', 'eventRejected = "callRejected"'):
        assert event in native
    assert "handlers?.onAnswer()" in native
    assert "handlers?.onReject()" in native
    assert "handlers?.onEnd()" in native


def test_manifest_registers_native_call_components():
    raw = MANIFEST.read_text(encoding="utf-8")
    assert "MANAGE_OWN_CALLS" in raw
    assert "FOREGROUND_SERVICE_PHONE_CALL" in raw
    assert ".call.CallForegroundService" in raw
    assert 'foregroundServiceType="phoneCall"' in raw
    assert ".call.IncomingCallReceiver" in raw
    assert ".call.CallConnectionService" in raw


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
    assert "MethodChannel('native_call')" in raw
    assert "nativeCalls.handleNativeMessage(call.method, call.arguments)" in raw
    assert "nativeCalls.restorePendingState()" in raw
    assert "'openIncomingCall'" not in raw and "'rejectIncomingCall'" not in raw
    coordinator = COORDINATOR.read_text(encoding="utf-8")
    incoming = coordinator.split("case 'incomingCall':", 1)[1].split("case 'callAccepted':", 1)[0]
    assert "arbiter.registerIncoming(callId)" in incoming
    assert "onPresentIncoming()" in incoming
    assert "calls.accept()" not in incoming and "answerFromUser(" not in incoming
    accepted = coordinator.split("case 'callAccepted':", 1)[1].split("case 'callRejected':", 1)[0]
    assert "await answerFromUser(callId)" in accepted
    rejected = coordinator.split("case 'callRejected':", 1)[1].split("case 'callEnded':", 1)[0]
    assert "arbiter.matchesPresentation(callId)" in rejected
    assert "await rejectFromUser()" in rejected
    ended = coordinator.split("case 'callEnded':", 1)[1].split("return true;", 1)[0]
    assert "arbiter.registerEnded(callId)" in ended
    assert "calls.hangup()" not in ended and "rejectFromUser(" not in ended
    assert "_endByPresentation(" not in ended
    answer = coordinator.split("Future<void> answerFromUser(", 1)[1].split("Future<void> rejectFromUser()", 1)[0]
    assert "arbiter.matchesPresentation(nativeCallId)" in answer
    assert "case CallPhase.ringing:" in answer and "if (_accepting) return;" in answer
    assert "await calls.accept()" in answer
    reject = coordinator.split("Future<void> rejectFromUser()", 1)[1].split("void onCallPhaseChanged()", 1)[0]
    assert "CallPhase.ringing" in reject and "await calls.reject()" in reject
    for phase in ("requestingPermission", "connecting", "connected"):
        assert f"CallPhase.{phase}" in reject
    assert "await calls.hangup()" in reject
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


def test_telecom_incoming_call_architecture():
    """规格§二/三/四/五/七：Telecom 接管来电（系统电话架构）。"""
    base = ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/com/liuhetong/mobile/call"
    cs = (base / "CallConnectionService.kt").read_text(encoding="utf-8")
    assert "addNewIncomingCall" in cs, "必须经 TelecomManager 上报系统来电"
    assert "PROPERTY_SELF_MANAGED" in cs
    assert "setRinging" in cs
    assert "onAnswer" in cs and "onReject" in cs

    cm = (base / "CallManager.kt").read_text(encoding="utf-8")
    assert "State.ringing" in cm and "State.active" in cm
    assert "hasActiveCall" in cm

    activity = (base / "CallActivity.kt").read_text(encoding="utf-8")
    assert "setShowWhenLocked" in activity, "锁屏之上显示（§测试3）"
    assert "setTurnScreenOn" in activity, "息屏点亮"
    assert "android.app.Activity" in activity, "纯 Native Activity（不依赖 Flutter）"

    bridge = (base / "CallBridge.kt").read_text(encoding="utf-8")
    assert 'channelName = "native_call"' in bridge, "规格§三通道"
    for m in ("answerCall", "rejectCall", "endCall", "getActiveCall"):
        assert m in bridge
    for e in ("incomingCall", "callAccepted", "callEnded"):
        assert e in bridge

    overlay = (base / "CallOverlayService.kt").read_text(encoding="utf-8")
    assert "TYPE_APPLICATION_OVERLAY" in overlay, "规格§五悬浮窗"
    assert "CallManager.returnToCall(applicationContext)" in overlay, "点击悬浮球返回同一通话"
    returning = cm.split("fun returnToCall(context: Context)", 1)[1].split("/**", 1)[0]
    assert "launchMainActivity(context)" in returning
    assert "onAnswerRequested()" not in returning and "onRejectRequested()" not in returning

    manifest = MANIFEST.read_text(encoding="utf-8")
    for perm in ("USE_FULL_SCREEN_INTENT", "SYSTEM_ALERT_WINDOW",
                 "POST_NOTIFICATIONS", "MANAGE_OWN_CALLS",
                 "FOREGROUND_SERVICE_PHONE_CALL"):
        assert perm in manifest, f"缺权限 {perm}"
    assert ".call.CallActivity" in manifest
    assert ".call.CallConnectionService" in manifest
    assert ".call.CallOverlayService" in manifest

    home = APP_HOME.read_text(encoding="utf-8")
    assert "MethodChannel('native_call')" in home, "Flutter 侧 native_call 装配"
    assert "nativeCalls.handleNativeMessage(call.method, call.arguments)" in home
    assert "if (call.method == 'returnToCall')" in home
    assert "callUi.restoreCall()" in home
    resume_idx = home.find("state == AppLifecycleState.resumed")
    assert home.find("callUi.showIncomingCall(calls)", resume_idx) > 0, \
        "§四：回前台必须自动进入通话页"


def test_old_noop_connection_service_removed():
    """旧空壳 ConnectionService 已由真实 Telecom 实现取代。"""
    old = (ROOT / "apps/mobile_flutter/android/app/src/main/kotlin/"
           "com/liuhetong/mobile/call/ChatFlowConnectionService.kt")
    assert not old.exists(), "空壳必须删除（CallConnectionService 取代）"
