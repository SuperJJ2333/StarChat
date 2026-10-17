import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/app_home.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/installation_reconciler.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;
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
    final reconciliation = Completer<InstallationResetOutcome>();
    var checks = 0;
    var factoryCalls = 0;
    var returned = false;
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    try {
      unawaited(app
          .main(
              dependencies: app.StartupDependencies(
            store: store,
            api: BusinessApiClient(
                baseUri: Uri.parse('https://synthetic.invalid'),
                sessionStore: store),
            reconcile: () {
              checks++;
              return reconciliation.future;
            },
            matrixFactory: (_) {
              factoryCalls++;
              throw StateError('retired startup reached factory');
            },
          ))
          .then((_) => returned = true));
      await tester.pump();
      expect(returned, isTrue,
          reason: 'runApp must happen before plugin/version/preferences waits');
      expect(find.byType(InstallationStartupGate), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(checks, 1,
          reason:
              'optional package metadata cannot block the necessary safety check');
      expect(packageInfo.isCompleted, isFalse);
      expect(tester.binding.sendFramesToEngine, isFalse);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.sendFramesToEngine, isFalse);
      expect(find.text('正在读取本地设置，请稍候'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.binding.sendFramesToEngine, isTrue);
      expect(
          find.byKey(const Key('installation-startup-retry')), findsOneWidget);
      reconciliation.complete(InstallationResetOutcome.notNeeded);
      packageInfo.complete({
        'appName': 'test',
        'packageName': 'test.invalid',
        'version': '0.0.1',
        'buildNumber': '1',
        'buildSignature': '',
      });
      await tester.pump();
      await tester.pump();
      expect(factoryCalls, 0,
          reason:
              'late minimum-check completion cannot create a retired owner');
      expect(find.byType(AppHome), findsNothing);
      expect(
          find.byKey(const Key('installation-startup-retry')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (!reconciliation.isCompleted) {
        reconciliation.complete(InstallationResetOutcome.notNeeded);
      }
      if (!packageInfo.isCompleted) {
        packageInfo.complete({
          'appName': 'test',
          'packageName': 'test.invalid',
          'version': '0.0.1',
          'buildNumber': '1',
          'buildSignature': '',
        });
      }
      await tester.pump();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });
}
