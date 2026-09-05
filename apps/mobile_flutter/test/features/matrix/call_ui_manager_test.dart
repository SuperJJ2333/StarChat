import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_notifications.dart';
import 'package:liuhetong_mobile/features/matrix/call_ui_manager.dart';

/// 通知网关测试替身：记录调用，不碰插件。
final class _RecordingCallNotifications implements CallNotificationGateway {
  final List<String> calls = <String>[];

  @override
  Future<void> showIncoming(
      {required String callerName, required bool video, bool ring = false}) async {
    calls.add('showIncoming(ring=$ring,video=$video)');
  }

  @override
  Future<void> hideIncoming() async => calls.add('hideIncoming');

  @override
  Future<void> showOngoing({required String title}) async =>
      calls.add('showOngoing');

  @override
  Future<void> hideOngoing() async => calls.add('hideOngoing');
}

final class _AllowedPermissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

final class _FakeCallBackend implements CallBackend {
  final events = StreamController<CallBackendEvent>.broadcast();

  @override
  Stream<CallBackendEvent> get callEvents => events.stream;

  @override
  bool get hasActiveSession => true;

  @override
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId) async =>
      true;

  @override
  Future<void> start(String roomId, String matrixUserId, CallMediaType type) async {}

  @override
  Future<void> accept() async {}

  @override
  Future<void> reject() async {}

  @override
  Future<void> hangup() async {}

  @override
  Future<void> setMuted(bool value) async {}

  @override
  Future<void> setSpeaker(bool value) async {}

  @override
  Future<void> switchCamera() async {}
}

CallBackendEvent _incoming({CallMediaType type = CallMediaType.audio}) =>
    CallBackendEvent.incoming(
        roomId: '!dm:example.test', matrixUserId: '@alice:example.test', type: type);

Future<void> _emit(
  WidgetTester tester,
  StreamController<CallBackendEvent> events,
  CallBackendEvent event,
) async {
  events.add(event);
  await tester.pump();
}

Future<void> _teardown(WidgetTester tester,
    StreamController<CallBackendEvent> events, CallUiManager manager) async {
  await _emit(tester, events, const CallBackendEvent.ended());
  await tester.pump(const Duration(seconds: 3)); // > closeDelay，页面关闭
  await tester.pump(const Duration(seconds: 62)); // 冲掉 60s 响铃超时计时器
  await tester.pumpAndSettle();
  await manager.detach();
}

void main() {
  // 规格验证场景 1/2：被叫处于任意页面（聊天/联系人页都是根 Navigator
  // 上的页面）→ 来电立即全屏覆盖。
  testWidgets('场景1/2 前台来电：任意页面之上立即弹出来电页', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final notifications = _RecordingCallNotifications();
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: notifications,
      isAppResumed: () => true,
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);

    // “聊天页”占位（任意业务页面）。
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('聊天页占位')),
    ));
    await _emit(tester, backend.events, _incoming());
    await tester.pumpAndSettle();

    expect(find.text('邀请你进行语音通话'), findsOneWidget,
        reason: '来电页必须盖在任意业务页面之上');
    expect(find.text('聊天页占位'), findsNothing);
    expect(
      notifications.calls.where((c) => c.startsWith('showIncoming')),
      isEmpty,
      reason: '前台来电不发展示系统通知（应用内铃声已覆盖；'
          'hideIncoming 为清残留通知的防御性调用）',
    );
    await _teardown(tester, backend.events, manager);
  });

  testWidgets('场景3 后台来电：系统全屏通知（ring 渠道），不推页面', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final notifications = _RecordingCallNotifications();
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: notifications,
      isAppResumed: () => false,
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('后台占位')),
    ));
    await _emit(tester, backend.events, _incoming(type: CallMediaType.video));

    expect(notifications.calls.single, 'showIncoming(ring=true,video=true)',
        reason: '后台/锁屏走系统全屏来电通知（calls_ring）');
    expect(find.text('邀请你进行视频通话'), findsNothing);
    await _teardown(tester, backend.events, manager);
  });

  testWidgets('场景4 接听后页面保持：connecting→connected→计时 00:01/00:02/00:03',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: _RecordingCallNotifications(),
      isAppResumed: () => true,
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('占位')),
    ));
    await _emit(tester, backend.events, _incoming());
    await tester.pumpAndSettle(const Duration(milliseconds: 50));

    // 点击接听：connecting → connected（页面绝不重建/退出）。
    await tester.tap(find.byKey(const Key('call-control-answer')));
    await tester.pump();
    expect(find.text('正在建立加密连接…'), findsOneWidget);
    await _emit(tester, backend.events, const CallBackendEvent.connected());
    await tester.pump();

    // 通话计时：逐秒推进，页面始终存在。
    expect(find.text('00:00'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:01'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:02'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:03'), findsOneWidget,
        reason: '场景4：接通后页面持续存在并走秒');
    await _teardown(tester, backend.events, manager);
  });

  testWidgets('状态抖动：connected 后短暂 ended 不立即关页，恢复即取消关闭',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: _RecordingCallNotifications(),
      isAppResumed: () => true,
      closeDelay: const Duration(seconds: 3),
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('占位')),
    ));
    await _emit(tester, backend.events, _incoming());
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('call-control-answer')));
    await tester.pump();
    await _emit(tester, backend.events, const CallBackendEvent.connected());
    await tester.pump();

    // 抖动：connected → ended → 3 秒内恢复 connected。
    await _emit(tester, backend.events, const CallBackendEvent.ended());
    await tester.pump(const Duration(seconds: 1));
    // 页面必须仍在（关闭延迟内），显示结束态而非被 pop。
    expect(find.text('通话已结束'), findsOneWidget,
        reason: 'hasConnectedOnce 后短暂 ended 不立即 pop（页面仍在栈内）');
    expect(find.text('占位'), findsNothing, reason: '底层页面不可见=通话页未关');
    await _emit(tester, backend.events, const CallBackendEvent.connected());
    await tester.pump(const Duration(seconds: 3));
    // 恢复后重新计秒（接通时刻刷新，pump 3 秒 → 00:03）。
    expect(find.text('00:03'), findsOneWidget, reason: '抖动恢复后关闭已取消，回到通话态并计秒');
    await _teardown(tester, backend.events, manager);
  });

  testWidgets('场景5 挂断：延迟后页面关闭，回到原页面', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: _RecordingCallNotifications(),
      isAppResumed: () => true,
      closeDelay: const Duration(seconds: 2),
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('主页占位')),
    ));
    await _emit(tester, backend.events, _incoming());
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('call-control-answer')));
    await tester.pump();
    await _emit(tester, backend.events, const CallBackendEvent.connected());
    await tester.pump();

    await tester.tap(find.byKey(const Key('call-control-hangup')));
    await tester.pump();
    expect(find.text('主页占位'), findsNothing, reason: '关闭延迟内页面仍在');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('主页占位'), findsOneWidget, reason: '挂断后页面关闭');
    await _teardown(tester, backend.events, manager);
  });

  test('未挂载 navigator 时查询状态安全（不抛异常）', () {
    final manager = CallUiManager(
      navigatorKey: GlobalKey<NavigatorState>(),
      notifications: _RecordingCallNotifications(),
      isAppResumed: () => true,
    );
    expect(manager.isIncomingPageOpen, isFalse);
    expect(manager.ringing, isFalse);
  });

  testWidgets('验证8：后台接听→connecting/connected，回前台补开通话页且不重复压入',
      (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final notifications = _RecordingCallNotifications();
    var resumed = false; // 用户返回应用后置 true。
    final manager = CallUiManager(
      navigatorKey: navigatorKey,
      notifications: notifications,
      isAppResumed: () => resumed,
    );
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
      now: () => tester.binding.clock.now(),
    );
    manager.attach(controller);
    await tester.pumpWidget(CupertinoApp(
      navigatorKey: navigatorKey,
      home: const Center(child: Text('主页占位')),
    ));

    // 后台来电：只发系统通知，不推页面。
    await _emit(tester, backend.events, _incoming());
    await tester.pump();
    expect(notifications.calls.single, contains('showIncoming(ring=true'),
        reason: '后台来电走系统通知');
    expect(manager.isIncomingPageOpen, isFalse);

    // 用户经原生通知接听（后台）：connecting 期间仍无页面。
    await controller.accept();
    await tester.pump();
    expect(controller.state.phase, CallPhase.connecting);
    expect(manager.isIncomingPageOpen, isFalse,
        reason: '后台接听阶段页面尚未挂载（由原生层呈现）');

    // 用户回到应用（app_home resume → showIncomingCall）：
    // connecting 且页面缺失 → 补开通话页。
    resumed = true;
    manager.showIncomingCall(controller);
    await tester.pumpAndSettle();
    expect(find.text('正在建立加密连接…'), findsOneWidget,
        reason: 'connecting 且页面缺失：恢复应用必须补开通话页');
    expect(manager.isIncomingPageOpen, isTrue);

    // connected 到达：页面保持，不重复压入第二页。
    await _emit(tester, backend.events, const CallBackendEvent.connected());
    await tester.pumpAndSettle();
    expect(manager.isIncomingPageOpen, isTrue);
    expect(find.text('正在建立加密连接…'), findsNothing,
        reason: '已接通，connecting 文案消失');
    expect(find.text('主页占位'), findsNothing, reason: '通话页仍在最上层');

    // 再次触发 showIncomingCall（重复 resume/重复事件）：不得重复压入。
    manager.showIncomingCall(controller);
    await tester.pumpAndSettle();
    expect(manager.isIncomingPageOpen, isTrue);
    expect(find.byKey(const Key('call-control-hangup')), findsOneWidget,
        reason: '通话页只压入一次（不重复压入页面）');

    await _teardown(tester, backend.events, manager);
  });
// ── 审计 P1（gallery-call-review）：回前台必须恢复来电页 ──────

testWidgets('审计复现：后台响铃 → 回前台 handleAppResumed → 来电页必须恢复',
    (tester) async {
  final navigatorKey = GlobalKey<NavigatorState>();
  final notifications = _RecordingCallNotifications();
  var resumed = false;
  final manager = CallUiManager(
    navigatorKey: navigatorKey,
    notifications: notifications,
    isAppResumed: () => resumed,
  );
  final backend = _FakeCallBackend();
  final controller = CallController(
    backend: backend,
    permissions: _AllowedPermissions(),
    now: () => tester.binding.clock.now(),
  );
  manager.attach(controller);
  await tester.pumpWidget(CupertinoApp(
    navigatorKey: navigatorKey,
    home: const Center(child: Text('主页占位')),
  ));

  // 后台来电：仅系统通知，未推页面。
  await _emit(tester, backend.events, _incoming(type: CallMediaType.video));
  await tester.pump();
  expect(manager.isIncomingPageOpen, isFalse, reason: '后台来电不推页面（既有语义）');

  // 用户回前台：真实生命周期入口只调 handleAppResumed（phase 无变化）。
  resumed = true;
  manager.handleAppResumed();
  await tester.pumpAndSettle();

  // 审计断言：来电页必须被恢复（此前仅取消通知，页面缺失）。
  expect(manager.isIncomingPageOpen, isTrue,
      reason: '回前台后必须补开来电页，而不是只把通知收掉');
  expect(find.text('邀请你进行视频通话'), findsOneWidget, reason: '来电内容可见');

  await _teardown(tester, backend.events, manager);
});
}
