import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/call_permission_readiness.dart';
import 'package:liuhetong_mobile/features/settings/notification/call_permission_checklist.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('chatflow/notification'), null);
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
}

class _Gateway implements CallPermissionReadinessGateway {
  int reads = 0;
  final actions = <CallPermissionAction>[];
  @override
  Future<CallPermissionReadiness> read() async {
    reads++;
    return const CallPermissionReadiness(
        android: true,
        microphone: false,
        camera: true,
        notifications: true,
        callChannel: true,
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
