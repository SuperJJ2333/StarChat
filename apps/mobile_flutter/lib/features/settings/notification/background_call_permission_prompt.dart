import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/notification/call_permission_readiness.dart';
import 'call_permission_checklist.dart';

const backgroundCallReminderKey =
    'chatflow.background_call_permissions.explained.v1';
bool _promptOpen = false;

/// Explains user-controlled OEM settings; acknowledging never means granted.
/// Returns false only when presentation should be retried at a safe time.
Future<bool> maybePromptBackgroundCallPermissions(
  BuildContext context, {
  CallPermissionReadinessGateway gateway =
      const SystemCallPermissionReadinessGateway(),
  bool Function()? canPresent,
}) async {
  if (_promptOpen || !(canPresent?.call() ?? true)) return false;
  _promptOpen = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(backgroundCallReminderKey) == true) return true;
    final readiness = await gateway.read();
    if (!readiness.android) return true;
    if (!context.mounted ||
        !(canPresent?.call() ?? true) ||
        ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    final openSettings = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('保持来电提醒'),
        content: const Text(
            '请在系统设置中检查并允许：\n\n自启动\n锁屏显示\n后台弹出界面\n显示悬浮窗\n\n这些设置有助于后台收到来电、显示接听页和返回通话。不同手机的名称可能不同，需由你手动开启。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('稍后设置'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('检查设置'),
          ),
        ],
      ),
    );
    if (openSettings == null) return false;
    await prefs.setBool(backgroundCallReminderKey, true);
    if (openSettings && context.mounted) {
      await Navigator.of(context, rootNavigator: true)
          .push(CupertinoPageRoute<void>(
        builder: (_) => CallPermissionSettingsPage(gateway: gateway),
      ));
    }
    return true;
  } finally {
    _promptOpen = false;
  }
}
