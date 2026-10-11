import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/installation_startup_gate.dart';
import 'package:liuhetong_mobile/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real entrypoint renders safely while package info is held',
      (tester) async {
    final packageInfo = Completer<Map<String, Object>>();
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => packageInfo.future);
    SharedPreferences.setMockInitialValues({});
    var returned = false;
    unawaited(app.main().then((_) => returned = true));
    await tester.pump();
    expect(returned, isTrue,
        reason: 'runApp must happen before plugin/version/preferences waits');
    expect(find.byType(InstallationStartupGate), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('正在启动畅聊'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('正在读取本地设置，请稍候'), findsOneWidget);
    expect(find.byKey(const Key('installation-startup-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    packageInfo.complete({
      'appName': 'test',
      'packageName': 'test.invalid',
      'version': '0.0.1',
      'buildNumber': '1',
      'buildSignature': '',
    });
    await tester.pump();
    await tester.pump();
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    expect(tester.takeException(), isNull);
  });
}
