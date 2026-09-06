import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/notification/call_permission_readiness.dart';
import 'package:liuhetong_mobile/features/settings/notification/background_call_permission_prompt.dart';

class _Gateway implements CallPermissionReadinessGateway {
  int actions = 0;
  @override
  Future<CallPermissionReadiness> read() async =>
      const CallPermissionReadiness(android: true, overlay: false);
  @override
  Future<bool> act(CallPermissionAction action) async {
    actions++;
    return true;
  }
}

void main() {
  testWidgets('reminds four settings once without granting them',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gateway = _Gateway();
    late BuildContext context;
    await tester.pumpWidget(CupertinoApp(home: Builder(builder: (c) {
      context = c;
      return const Text('home');
    })));
    final prompt =
        maybePromptBackgroundCallPermissions(context, gateway: gateway);
    await tester.pumpAndSettle();
    for (final label in ['自启动', '锁屏显示', '后台弹出界面', '显示悬浮窗']) {
      expect(find.textContaining(label), findsWidgets);
    }
    expect(gateway.actions, 0);
    await tester.tap(find.text('稍后设置'));
    await tester.pumpAndSettle();
    await prompt;
    await maybePromptBackgroundCallPermissions(context, gateway: gateway);
    await tester.pumpAndSettle();
    expect(find.text('保持来电提醒'), findsNothing);
  });

  testWidgets('active call defers reminder without marking it acknowledged',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    late BuildContext context;
    await tester.pumpWidget(CupertinoApp(home: Builder(builder: (c) {
      context = c;
      return const Text('home');
    })));
    final deferred = await maybePromptBackgroundCallPermissions(context,
        gateway: _Gateway(), canPresent: () => false);
    expect(deferred, false);
    expect(find.text('保持来电提醒'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(backgroundCallReminderKey), isNull);
    final retry = maybePromptBackgroundCallPermissions(context,
        gateway: _Gateway(), canPresent: () => true);
    await tester.pumpAndSettle();
    expect(find.text('保持来电提醒'), findsOneWidget);
    await tester.tap(find.text('稍后设置'));
    await tester.pumpAndSettle();
    expect(await retry, true);
    expect(
        await maybePromptBackgroundCallPermissions(context,
            gateway: _Gateway()),
        true);
    expect(find.text('保持来电提醒'), findsNothing);
  });
}
