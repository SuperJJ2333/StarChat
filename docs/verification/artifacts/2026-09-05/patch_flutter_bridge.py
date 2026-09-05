from pathlib import Path

p = Path('apps/mobile_flutter/lib/app_home.dart')
raw = p.read_text(encoding='utf-8')

# 1) 装配（initState 内 callUi.attach 之前）
marker = "    _nativeCallChannel = const MethodChannel('chatflow/call');"
inject = """_nativePushBridge = NativePushBridge(
      onPushMessage: () async {
        // 推送唤醒兜底通知（通用文案，无业务内容）；详细通知由
        // Matrix 同步路径的 NotificationCoordinator 产出。
        final coordinator = NotificationSystemHandle.coordinator;
        if (coordinator != null) {
          await coordinator.showPushWakeNotification();
        }
      },
      onFriendRequest: () async {
        // 好友申请：桌面角标 + 通讯录红点（登录会话内）。
        await NotificationSystemHandle.coordinator?.refreshLauncherBadge();
        if (mounted) {
          pendingFriendRequests.value = pendingFriendRequests.value + 1;
        }
      },
    );
    unawaited(_nativePushBridge!.install());
    _nativeCallChannel = const MethodChannel('chatflow/call');"""
assert marker in raw
raw = raw.replace(marker, inject, 1)

# 2) 字段 + dispose 卸载
field_anchor = "  MethodChannel? _nativeCallChannel;"
raw = raw.replace(
    field_anchor,
    "  NativePushBridge? _nativePushBridge;\n" + field_anchor, 1)
disp_anchor = "    calls.removeListener(_handleCallState);"
raw = raw.replace(
    disp_anchor,
    "    unawaited(_nativePushBridge?.uninstall());\n" + disp_anchor, 1)

# 3) import
if "native_push_bridge.dart" not in raw:
    raw = raw.replace(
        "import 'features/push/push_status_registry.dart';",
        "import 'features/push/native_push_bridge.dart';\n"
        "import 'features/push/push_status_registry.dart';", 1)
p.write_text(raw, encoding='utf-8', newline='')
print('app_home OK')
