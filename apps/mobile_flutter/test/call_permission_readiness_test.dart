import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:liuhetong_mobile/core/notification/call_permission_readiness.dart';
import 'package:liuhetong_mobile/features/settings/notification/call_permission_checklist.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('chatflow/notification'), null);
  });
  for (final entry in {
    CallPermissionAction.microphone: Permission.microphone,
    CallPermissionAction.camera: Permission.camera,
  }.entries) {
    test(
        '${entry.key} already permanently denied opens settings without request',
        () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('flutter.baseflow.com/permissions/methods'),
              (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'checkPermissionStatus' => PermissionStatus.permanentlyDenied.index,
          'openAppSettings' => true,
          _ => throw MissingPluginException(),
        };
      });
      expect(await const SystemCallPermissionReadinessGateway().act(entry.key),
          true);
      expect(calls, ['checkPermissionStatus', 'openAppSettings']);
    });
    for (final requested in [
      PermissionStatus.permanentlyDenied,
      PermissionStatus.denied,
      PermissionStatus.restricted,
      PermissionStatus.granted,
    ]) {
      for (final settingsOpened in [false, true]) {
        test('${entry.key} request $requested with settings $settingsOpened',
            () async {
          final calls = <MethodCall>[];
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                  const MethodChannel(
                      'flutter.baseflow.com/permissions/methods'),
                  (call) async {
            calls.add(call);
            return switch (call.method) {
              'checkPermissionStatus' => PermissionStatus.denied.index,
              'requestPermissions' => {entry.value.value: requested.index},
              'openAppSettings' => settingsOpened,
              _ => throw MissingPluginException(),
            };
          });

          final result =
              await const SystemCallPermissionReadinessGateway().act(entry.key);

          expect(
              result,
              requested.isGranted ||
                  (requested.isPermanentlyDenied && settingsOpened));
          expect(calls.map((call) => call.method), [
            'checkPermissionStatus',
            'requestPermissions',
            if (requested.isPermanentlyDenied) 'openAppSettings',
          ]);
          expect(calls[0].arguments, entry.value.value);
          expect(calls[1].arguments, [entry.value.value]);
        });
      }
    }
  }
  test('iOS readiness fallback checks permissions without prompting', () async {
    final permissions = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
      expect(call.method, 'checkPermissionStatus');
      permissions.add(call.arguments as int);
      return call.arguments == Permission.camera.value
          ? PermissionStatus.permanentlyDenied.index
          : PermissionStatus.granted.index;
    });
    final state = await const SystemCallPermissionReadinessGateway().read();
    expect(state.android, false);
    expect(state.microphone, true);
    expect(state.camera, false);
    expect(state.notifications, true);
    expect(permissions, [
      Permission.microphone.value,
      Permission.camera.value,
      Permission.notification.value,
    ]);
  });
  test('denied notifications retain notification settings then app fallback',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('chatflow/notification'),
            (call) async {
      calls.add(call.method);
      return false;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter.baseflow.com/permissions/methods'),
            (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'checkPermissionStatus' => PermissionStatus.denied.index,
        'requestPermissions' => {
            Permission.notification.value:
                PermissionStatus.permanentlyDenied.index
          },
        'openAppSettings' => true,
        _ => throw MissingPluginException(),
      };
    });
    expect(
        await const SystemCallPermissionReadinessGateway()
            .act(CallPermissionAction.notifications),
        true);
    expect(calls, [
      'checkPermissionStatus',
      'requestPermissions',
      'openNotificationSettings',
      'openAppSettings',
    ]);
  });
  test(
      'explicit settings actions target the actual call channels and special access',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('chatflow/notification'),
            (call) async {
      calls.add(call);
      return true;
    });
    const gateway = SystemCallPermissionReadinessGateway();
    for (final action in [
      CallPermissionAction.callChannel,
      CallPermissionAction.ongoingChannel,
      CallPermissionAction.fullScreen,
      CallPermissionAction.overlay
    ]) {
      expect(await gateway.act(action), true);
    }
    expect(calls.map((call) => call.method), [
      'openChannelSettings',
      'openChannelSettings',
      'openFullScreenSettings',
      'openOverlaySettings'
    ]);
    expect(calls[0].arguments, {'channelId': 'calls_ring'});
    expect(calls[1].arguments, {'channelId': 'chatflow_silent'});
  });
  test('native query is read only and preserves unknown channel state',
      () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('chatflow/notification'),
            (call) async {
      calls.add(call.method);
      return {
        'microphone': true,
        'camera': false,
        'notifications': true,
        'overlay': false,
        'fullScreenRequired': false,
        'android': true
      };
    });
    final state = await const SystemCallPermissionReadinessGateway().read();
    expect(state.microphone, true);
    expect(state.camera, false);
    expect(state.callChannel, isNull);
    expect(state.overlay, false);
    expect(calls, ['getCallPermissionReadiness']);
  });
  testWidgets('checklist reads without prompting and refreshes on resume',
      (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(
        CupertinoApp(home: CallPermissionSettingsPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(gateway.reads, 1);
    expect(gateway.actions, isEmpty);
    expect(find.text('麦克风'), findsOneWidget);
    expect(find.text('通话悬浮窗'), findsOneWidget);
    await tester.tap(find.text('麦克风'));
    await tester.pumpAndSettle();
    expect(gateway.actions, [CallPermissionAction.microphone]);
    final reads = gateway.reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(gateway.reads, greaterThan(reads));
  });

  /// 微信级加载模型（2026-09-19 审计）：不可知（null）的重读不得把已知状态
  /// 降级成「待检查」——原先 `_refresh` 整体替换 `_state`。
  test('mergedWith keeps known values when a re-read reports unknown', () {
    const known = CallPermissionReadiness(
        android: true,
        microphone: true,
        camera: false,
        notifications: true,
        callChannel: true,
        overlay: false,
        fullScreenRequired: true,
        fullScreen: false);
    const unknown = CallPermissionReadiness(android: false);

    final merged = unknown.mergedWith(known);

    expect(merged.microphone, isTrue);
    expect(merged.camera, isFalse, reason: '已知的 false 也要保留');
    expect(merged.notifications, isTrue);
    expect(merged.callChannel, isTrue);
    expect(merged.overlay, isFalse);
    expect(merged.fullScreen, isFalse);
    expect(merged.android, isTrue, reason: 'android 是设备事实，一旦为真保持为真');
    expect(merged.fullScreenRequired, isTrue);
    expect(
        const CallPermissionReadiness(android: true)
            .mergedWith(null)
            .microphone,
        isNull);
  });

  testWidgets('unknown re-read does not downgrade the known checklist state',
      (tester) async {
    final gateway = _Gateway()..unknownAfterFirstRead = true;
    await tester.pumpWidget(
        CupertinoApp(home: CallPermissionSettingsPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('已开启'), findsWidgets);
    expect(find.text('待检查'), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(gateway.reads, greaterThan(1));

    expect(find.text('待检查'), findsNothing,
        reason: '不可知的重读不得把「已开启/未开启」降级成「待检查」');
    expect(find.text('已开启'), findsWidgets);
  });
}

class _Gateway implements CallPermissionReadinessGateway {
  int reads = 0;
  bool unknownAfterFirstRead = false;
  final actions = <CallPermissionAction>[];
  @override
  Future<CallPermissionReadiness> read() async {
    reads++;
    if (unknownAfterFirstRead && reads > 1) {
      // 平台查询失败/不可用：字段全为 null（android 也读不到）。
      return const CallPermissionReadiness();
    }
    return const CallPermissionReadiness(
        android: true,
        microphone: false,
        camera: true,
        notifications: true,
        callChannel: true,
        ongoingChannel: true,
        overlay: false,
        fullScreenRequired: true,
        fullScreen: false);
  }

  @override
  Future<bool> act(CallPermissionAction action) async {
    actions.add(action);
    return true;
  }
}
