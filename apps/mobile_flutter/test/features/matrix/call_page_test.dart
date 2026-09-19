import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

import 'call_backend_test_defaults.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_page.dart';
import 'package:liuhetong_mobile/ui/foundation/changliao_icons.dart';

final class _AllowedPermissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

final class _FakeCallBackend with CallBackendTestDefaults {
  final events = StreamController<CallBackendEvent>.broadcast();
  int accepts = 0;
  int rejects = 0;

  @override
  bool get hasActiveSession => true;
  int hangups = 0;
  bool? muted;
  bool? speaker;
  int cameraSwitches = 0;

  @override
  Stream<CallBackendEvent> get callEvents => events.stream;

  @override
  Future<void> accept() async => accepts++;

  @override
  Future<void> hangup() async => hangups++;

  @override
  Future<bool> isEncryptedDirectRoom(
          String roomId, String matrixUserId) async =>
      true;

  @override
  Future<void> reject() async => rejects++;

  @override
  Future<void> setMuted(bool value) async => muted = value;

  @override
  Future<void> setSpeaker(bool value) async => speaker = value;

  @override
  Future<void> start(
      String roomId, String matrixUserId, CallMediaType type) async {}

  @override
  Future<void> switchCamera() async => cameraSwitches++;
}

Future<void> _emit(
  WidgetTester tester,
  _FakeCallBackend backend,
  CallBackendEvent event,
) async {
  backend.events.add(event);
  await tester.pump();
}

void main() {
  testWidgets('incoming encrypted call exposes answer and reject actions',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          incoming: true,
        ),
      ),
    );

    expect(find.text('周然 语音通话'), findsOneWidget);
    expect(find.text('邀请你进行语音通话'), findsOneWidget);
    expect(find.byKey(const Key('call-control-answer')), findsOneWidget);
    expect(find.byKey(const Key('call-control-reject')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-control-answer')));
    await tester.pump();
    expect(backend.accepts, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('BUG-22 视频来电的接听按钮使用视频图标', (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.video,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          incoming: true,
        ),
      ),
    );

    expect(find.text('周然 视频通话'), findsOneWidget);
    expect(find.byKey(const Key('call-control-answer')), findsOneWidget);
    expect(find.byIcon(ChangliaoIcons.videoCallFilled), findsOneWidget,
        reason: '视频来电的接听必须是视频图标，让用户一眼区分来电类型');
    expect(find.byIcon(ChangliaoIcons.voiceCallFilled), findsNothing,
        reason: '接听按钮不得与语音来电共用话筒图标');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('BUG-23 通话结束自动关闭时回调 onEnded(roomId) 且仅一次',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    final endedRoomIds = <String>[];
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          incoming: true,
          autoCloseOnEnd: true,
          onEnded: endedRoomIds.add,
        ),
      ),
    );

    // 接通再挂断：结束路径带缓冲，回调必须在关闭时携带 roomId 触发。
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump(const Duration(seconds: 4));

    expect(endedRoomIds, ['!dm:example.test'],
        reason: '结束后应回调一次 roomId，供会话层推进已读（消除通话虚增未读）');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('BUG-23 回归：来电页不自动关闭时终态仍触发 onEnded 一次',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    final endedRoomIds = <String>[];
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          incoming: true,
          onEnded: endedRoomIds.add,
        ),
      ),
    );

    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();

    expect(endedRoomIds, ['!dm:example.test'],
        reason: 'autoCloseOnEnd=false（来电/最小化路径）也必须通知会话层推进已读');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('BUG-23 抖动恢复后再次终态会再次通知（幂等推进已读）',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    final endedRoomIds = <String>[];
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          incoming: true,
          onEnded: endedRoomIds.add,
        ),
      ),
    );

    // 先接通，再终态。控制器对终态后的 connected 是粘性的（忽略恢复），
    // 因此 onEnded 只应触发一次。
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();

    expect(endedRoomIds, ['!dm:example.test'],
        reason: '终态粘性：无论后续 connected/ended 事件如何，onEnded 只通知一次'
            '（markRoomRead 幂等，重复推进无意义）');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('connected call shows encrypted controls and toggled state',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );
    await _emit(tester, backend, const CallBackendEvent.connected());

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
        ),
      ),
    );

    expect(find.text('00:00'), findsOneWidget, reason: '接通后展示通话时长');
    expect(find.byKey(const Key('call-control-microphone')), findsOneWidget);
    expect(find.byKey(const Key('call-control-hangup')), findsOneWidget);
    expect(find.byKey(const Key('call-control-speaker')), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-control-microphone')));
    await tester.pump();
    expect(backend.muted, isTrue);
    expect(find.byIcon(CupertinoIcons.mic_slash), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('connected video call exposes camera switch with a real icon',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.video,
      ),
    );
    await _emit(tester, backend, const CallBackendEvent.connected());

    await tester.pumpWidget(
      CupertinoApp(
        home: CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
        ),
      ),
    );

    expect(find.text('周然 视频通话'), findsOneWidget);
    expect(find.byIcon(ChangliaoIcons.switchCamera), findsOneWidget);
    await tester.tap(find.byKey(const Key('call-control-camera')));
    expect(backend.cameraSwitches, 1);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('hasConnectedOnce：接通后短暂 ended 不立即退出，抖动恢复取消退出',
      (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );

    await tester.pumpWidget(const CupertinoApp(home: Placeholder()));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
      CupertinoPageRoute<void>(
        builder: (_) => CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          autoCloseOnEnd: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();

    // 短暂 ended（网络抖动）：3 秒缓冲内不 pop。
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2500));
    expect(find.text('通话已结束'), findsOneWidget,
        reason: '接通过一次的 ended 有缓冲期，页面不立即退出');

    // 抖动恢复 connected：退出取消，页面回到通话态。
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();
    expect(find.byKey(const Key('call-status')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('autoCloseOnEnd：缓冲期过后真的退出（挂断关页）', (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );
    await tester.pumpWidget(const CupertinoApp(home: Placeholder()));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
      CupertinoPageRoute<void>(
        builder: (_) => CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          autoCloseOnEnd: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _emit(tester, backend, const CallBackendEvent.connected());
    await tester.pump();
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();
    expect(find.text('通话已结束'), findsOneWidget);
    // 缓冲期（3s）过后退出。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('通话已结束'), findsNothing, reason: '挂断后页面最终关闭');
    controller.dispose();
    await backend.events.close();
  });

  testWidgets('未接通的 ended 立即退出（不拖失败页）', (tester) async {
    final backend = _FakeCallBackend();
    final controller = CallController(
      backend: backend,
      permissions: _AllowedPermissions(),
    );
    await _emit(
      tester,
      backend,
      const CallBackendEvent.incoming(
        roomId: '!dm:example.test',
        matrixUserId: '@alice:example.test',
        type: CallMediaType.audio,
      ),
    );
    await tester.pumpWidget(const CupertinoApp(home: Placeholder()));
    tester.state<NavigatorState>(find.byType(Navigator)).push(
      CupertinoPageRoute<void>(
        builder: (_) => CallPage(
          controller: controller,
          displayName: '周然',
          fallbackSeed: 'alice',
          autoCloseOnEnd: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _emit(tester, backend, const CallBackendEvent.ended());
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('通话已结束'), findsNothing,
        reason: '从未接通（拒接/取消）时立即退出，不保留结束页');
    controller.dispose();
    await backend.events.close();
  });
}
