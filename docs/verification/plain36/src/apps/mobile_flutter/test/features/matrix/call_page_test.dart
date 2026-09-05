import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/call_page.dart';
import 'package:liuhetong_mobile/ui/foundation/changliao_icons.dart';

final class _AllowedPermissions implements CallPermissionGateway {
  @override
  Future<bool> request({required bool video}) async => true;
}

final class _FakeCallBackend implements CallBackend {
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
