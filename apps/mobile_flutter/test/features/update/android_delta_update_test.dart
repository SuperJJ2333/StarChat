import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:liuhetong_mobile/core/maintenance_activity.dart';
import 'package:liuhetong_mobile/features/update/app_update.dart';
import 'package:liuhetong_mobile/features/update/android_delta_update.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('chatflow/android_delta');
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  for (final reason in ['cancel', 'pressure', 'background']) {
    test(
        'held pause response then $reason never prepares or installs and releases lease',
        () async {
      final pauseEntered = Completer<void>();
      final pauseReply = Completer<void>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'paused' && !pauseEntered.isCompleted) {
          pauseEntered.complete();
          await pauseReply.future;
        }
        return switch (call.method) {
          'prepare' => 'ready',
          'install' => 'installer_opened',
          _ => null
        };
      });
      final gate = MaintenanceActivity.instance;
      gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final result =
          AndroidDeltaUpdater.run(const AndroidDeltaEnvelope('{}', 'AA=='));
      await pauseEntered.future;
      expect(gate.heavyBusy, isTrue);
      try {
        switch (reason) {
          case 'cancel':
            await AndroidDeltaUpdater.cancel();
          case 'pressure':
            gate.pressure();
          case 'background':
            gate.didChangeAppLifecycleState(AppLifecycleState.paused);
        }
        pauseReply.complete();
        expect(await result, DeltaUpdateOutcome.cancelled);
        expect(calls, isNot(contains('prepare')));
        expect(calls, isNot(contains('install')));
        expect(gate.heavyBusy, isFalse);
      } finally {
        if (!pauseReply.isCompleted) pauseReply.complete();
        await result;
        gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
      }
    });
  }
  test(
      'background cancels APK preparation releases lease and other background work progresses',
      () async {
    final prepared = Completer<void>();
    final native = Completer<String>();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepare') {
        prepared.complete();
        return native.future;
      }
      if (call.method == 'cancel' && !native.isCompleted) {
        native.complete('cancelled');
      }
      return null;
    });
    final gate = MaintenanceActivity.instance;
    gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
    final result =
        AndroidDeltaUpdater.run(const AndroidDeltaEnvelope('{}', 'AA=='));
    await prepared.future;
    expect(gate.heavyBusy, isTrue);
    final other = gate.acquireHeavy();
    MaintenanceLease? otherLease;
    try {
      gate.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(await result.timeout(const Duration(seconds: 1)),
          DeltaUpdateOutcome.cancelled);
      expect(calls, isNot(contains('install')));
      otherLease = await other.timeout(const Duration(seconds: 1));
      expect(otherLease, isNotNull);
      expect(gate.isForeground, isFalse);
    } finally {
      if (!native.isCompleted) native.complete('cancelled');
      await result;
      otherLease ??= await other;
      otherLease?.release();
      gate.didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
  });
  test(
      'bridge sends only envelope and shows required system install permission',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'prepare') {
        expect(MaintenanceActivity.instance.heavyBusy, isTrue);
      }
      return switch (call.method) {
        'prepare' => 'ready',
        'install' => 'permission_required',
        _ => null
      };
    });
    expect(
        await AndroidDeltaUpdater.run(const AndroidDeltaEnvelope('{}', 'AA==')),
        DeltaUpdateOutcome.permissionRequired);
    final prepare = calls.singleWhere((call) => call.method == 'prepare');
    expect(prepare.arguments, {
      'delta': {'signed_payload': '{}', 'signature': 'AA=='}
    });
    expect(calls.any((call) => call.method == 'install'), isTrue);
    expect(MaintenanceActivity.instance.heavyBusy, isFalse);
    await AndroidDeltaUpdater.requestPermission();
    expect(calls.last.method, 'permission');
  });
  test('cancelling while waiting for interaction idle never prepares an APK',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    final gate = MaintenanceActivity.instance;
    gate.setInteractive('update-test', true);
    final result =
        AndroidDeltaUpdater.run(const AndroidDeltaEnvelope('{}', 'AA=='));
    await AndroidDeltaUpdater.cancel();
    gate.setInteractive('update-test', false);
    expect(await result, DeltaUpdateOutcome.cancelled);
    expect(calls, isNot(contains('prepare')));
  });
  const plain = AppUpdateInfo(
      latestVersion: '1',
      latestBuild: 4,
      minSupportedBuild: 1,
      notes: '',
      apkUrl: 'https://example.com/full.apk');
  test('absent unsigned oversized metadata and iOS safely use full APK',
      () async {
    for (final metadata in [
      null,
      {'signed_payload': '{}'},
      {'signed_payload': 'x' * 20000, 'signature': 'x'}
    ]) {
      final info = AppUpdateInfo.fromMap({
        'latest_build': 4,
        'download_url': plain.downloadUrl,
        'android_delta': metadata
      });
      final calls = <String>[];
      await launchAppUpdate(info,
          android: true,
          launchExternal: (url) async => calls.add(url),
          native: (_) async {
            fail('untrusted metadata reached native');
          });
      expect(calls, [plain.downloadUrl]);
    }
    final info = AppUpdateInfo.fromMap({
      'latest_build': 4,
      'download_url': plain.downloadUrl,
      'android_delta': {'signed_payload': '{}', 'signature': 'AA=='}
    });
    final calls = <String>[];
    await launchAppUpdate(info,
        android: false,
        launchExternal: (url) async => calls.add(url),
        native: (_) async {
          fail('iOS invoked Android');
        });
    expect(calls, [plain.downloadUrl]);
  });
  test('native trust failure and cancellation remain distinct', () async {
    final info = AppUpdateInfo.fromMap({
      'latest_build': 4,
      'download_url': plain.downloadUrl,
      'android_delta': {'signed_payload': '{}', 'signature': 'AA=='}
    });
    final calls = <String>[];
    await launchAppUpdate(info,
        android: true,
        launchExternal: (url) async => calls.add(url),
        native: (_) async => DeltaUpdateOutcome.fallback);
    expect(calls, [plain.downloadUrl]);
    calls.clear();
    await launchAppUpdate(info,
        android: true,
        launchExternal: (url) async => calls.add(url),
        native: (_) async => DeltaUpdateOutcome.cancelled);
    expect(calls, isEmpty);
  });
}
