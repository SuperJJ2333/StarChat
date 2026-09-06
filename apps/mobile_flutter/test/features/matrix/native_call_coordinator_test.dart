import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';
import 'package:liuhetong_mobile/features/matrix/call_alerts.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart';
import 'package:liuhetong_mobile/features/matrix/native_call_coordinator.dart';

final class FakePermissions implements CallPermissionGateway {
  bool allowed = true;
  Completer<bool>? pending;
  @override
  Future<bool> request({required bool video}) async =>
      pending?.future ?? allowed;
}

final class NoopAlerts extends CallAlerts {
  NoopAlerts() : super(driver: _NoopDriver());
}

final class _NoopDriver implements CallAlertDriver {
  @override
  Future<void> startRingtone(SoundType ringtone) async {}
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> vibrate() async {}
}

final class FakeBackend implements CallBackend {
  final events = StreamController<CallBackendEvent>.broadcast();
  int accepts = 0;
  int rejects = 0;
  int hangups = 0;
  bool activeSession = true;

  void ring({bool video = false}) {
    events.add(CallBackendEvent.incoming(
      roomId: '!dm:example.test',
      matrixUserId: '@alice:example.test',
      type: video ? CallMediaType.video : CallMediaType.audio,
    ));
  }

  @override
  Stream<CallBackendEvent> get callEvents => events.stream;
  @override
  bool get hasActiveSession => activeSession;
  @override
  Future<bool> isEncryptedDirectRoom(
          String roomId, String matrixUserId) async =>
      true;
  @override
  Future<void> start(
      String roomId, String matrixUserId, CallMediaType type) async {}
  @override
  Future<void> accept() async => accepts++;
  @override
  Future<void> reject() async => rejects++;
  @override
  Future<void> hangup() async => hangups++;
  @override
  Future<void> setMuted(bool value) async {}
  @override
  Future<void> setSpeaker(bool value) async {}
  @override
  Future<void> switchCamera() async {}
}

/// 记录型 native_call 通道替身（冷启动 ready/getActiveCall 数据注入）。
final class FakeNativeChannel implements NativeCallChannel {
  FakeNativeChannel({this.readyResult});

  Object? readyResult;
  final invocations = <(String, Object?)>[];

  @override
  Future<Object?> invoke(String method, [Object? arguments]) async {
    invocations.add((method, arguments));
    if (method == 'ready') return readyResult;
    if (method == 'getActiveCall') {
      return {'state': 'idle', 'callId': null, 'video': false};
    }
    return true;
  }

  Iterable<String> get reportStates => invocations
      .where((entry) => entry.$1 == 'reportCallState')
      .map((entry) => (entry.$2 as Map)['phase'] as String);
}

/// 泵若干事件循环，让广播事件/microtask 链（响铃→监听→待接听→accept）走完。
Future<void> pumpEventLoop() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeBackend backend;
  late CallController calls;
  late FakeNativeChannel channel;
  late NativeCallCoordinator coordinator;
  var presented = 0;
  var dismissed = 0;

  setUp(() {
    backend = FakeBackend();
    calls = CallController(
      backend: backend,
      permissions: FakePermissions(),
      alerts: NoopAlerts(),
    );
    channel = FakeNativeChannel();
    presented = 0;
    dismissed = 0;
    coordinator = NativeCallCoordinator(
      calls: calls,
      onPresentIncoming: () => presented++,
      onDismissNativeLayer: () => dismissed++,
      channel: channel,
    );
    // AppHome 同款接线：控制器相位变化 → 协调器钩子。
    calls.addListener(coordinator.onCallPhaseChanged);
  });

  tearDown(() {
    calls.dispose();
  });

  test('native denied answer keeps presentation until user retries', () async {
    (calls.permissions as FakePermissions).allowed = false;
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-1'});
    backend.ring();
    await pumpEventLoop();
    await coordinator.answerFromUser('call-1');
    expect(calls.state.phase, CallPhase.ringing);
    expect(dismissed, 0);
    expect(backend.rejects, 0);
    expect(channel.reportStates.last, 'ringing');
    (calls.permissions as FakePermissions).allowed = true;
    await coordinator.answerFromUser('call-1');
    expect(backend.accepts, 1);
    expect(dismissed, 1);
  });

  test('验证1：incomingCall 到达但用户未操作 → accept 调用次数为零', () async {
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-1'});
    backend.ring();
    await pumpEventLoop();

    expect(backend.accepts, 0, reason: '来电事件只登记呈现，绝不触发接听');
    expect(presented, greaterThanOrEqualTo(1), reason: '来电仍应呈现');
    expect(calls.state.phase, CallPhase.ringing);
  });

  test('验证2：明确点击接听 → 只对对应通话执行一次（重复事件不重复接听）', () async {
    backend.ring();
    await pumpEventLoop();
    expect(calls.state.phase, CallPhase.ringing);

    await coordinator.handleNativeMessage('callAccepted', {'callId': 'call-1'});
    expect(backend.accepts, 1);

    // 双通道/重复点击/重复事件：不再执行第二次 accept。
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'call-1'});
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'call-1'});
    expect(backend.accepts, 1,
        reason: '接听处理中（requestingPermission/connecting）不得重复接听');
    expect(calls.state.phase, CallPhase.connecting);
  });

  test('验证2b：用户接听早于 Matrix 响铃同步 → 响铃到达即接听一次', () async {
    // 推送唤醒先到（incomingCall 登记），用户在原生通知上点[接听]，
    // 此时 Matrix 响铃尚未同步（phase idle）→ 登记绑定式待接听。
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-9'});
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'call-9'});
    expect(backend.accepts, 0, reason: '未确定关联真实 Matrix 通话前不得接听');

    // Matrix 响铃同步到达 → 消费待接听，恰好接听一次。
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 1, reason: '绑定式待接听在响铃到达后恰好接听一次');
    expect(calls.state.phase, CallPhase.connecting);
  });

  test('验证4：待接听过期后，下一通电话不会被自动接听', () async {
    var now = DateTime(2026, 9, 5, 12, 0, 0);
    final arbiter = NativeCallArbiter(clock: () => now);
    final expired = NativeCallCoordinator(
      calls: calls,
      onPresentIncoming: () {},
      channel: channel,
      arbiter: arbiter,
    );
    await expired.handleNativeMessage('incomingCall', {'callId': 'call-a'});
    await expired.handleNativeMessage('callAccepted', {'callId': 'call-a'});
    expect(backend.accepts, 0);

    // 超过期限（15s）后原通话的 Matrix 响铃才到：请求已过期，丢弃。
    now = now.add(const Duration(seconds: 16));
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 0, reason: '过期请求不得应用到当前通话');

    // 用户没有再次点接听：这通电话保持响铃，绝不自动接听。
    expect(calls.state.phase, CallPhase.ringing);
  });

  test('验证4b：原生通话结束 → 待接听作废；新通话不被旧请求串扰', () async {
    var now = DateTime(2026, 9, 5, 12, 0, 0);
    final arbiter = NativeCallArbiter(clock: () => now);
    final c2 = NativeCallCoordinator(
      calls: calls,
      onPresentIncoming: () {},
      channel: channel,
      arbiter: arbiter,
    );
    await c2.handleNativeMessage('incomingCall', {'callId': 'call-a'});
    await c2.handleNativeMessage('callAccepted', {'callId': 'call-a'});
    expect(arbiter.hasPendingAnswer, isTrue);

    // 原通话被远端取消（原生 60s 超时 → callEnded）。
    await c2.handleNativeMessage('callEnded', {'callId': 'call-a'});
    expect(arbiter.hasPendingAnswer, isFalse, reason: '对应通话结束即作废待接听');

    // 新一通电话的响铃到达：不受旧请求影响。
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 0, reason: '旧通话的接听请求不得应用到下一通电话');
  });

  test('验证5：重复推送（incomingCall 重复事件）不产生接听/拒绝副作用', () async {
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-1'});
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-1'});
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-1'});
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 0);
    expect(backend.rejects, 0);
  });

  test('验证3：冷启动 ready 握手恢复暂存的接听动作（动作保留/恢复/一次消费）', () async {
    // 模拟原生暂存：ready 返回待处理 answer 动作（时间新鲜）。
    final coldStart = FakeNativeChannel(readyResult: {
      'actions': [
        {
          'callId': 'call-cold',
          'action': 'answer',
          'at': DateTime.now().millisecondsSinceEpoch,
        }
      ],
      'activeCall': {'state': 'ringing', 'callId': 'call-cold'},
    });
    final c3 = NativeCallCoordinator(
      calls: calls,
      onPresentIncoming: () {},
      channel: coldStart,
    );
    calls.addListener(c3.onCallPhaseChanged);
    await c3.restorePendingState();
    await pumpEventLoop();
    // Matrix 响铃同步到达 → 待接听被消费，恰好接听一次。
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 1, reason: '冷启动暂存的接听动作恢复后恰好执行一次');
    expect(
      coldStart.invocations.any((e) => e.$1 == 'ready'),
      isTrue,
      reason: '恢复必须经 ready 握手（原生侧取出即标记消费）',
    );
    expect(
      coldStart.invocations.any((e) => e.$1 == 'getActiveCall'),
      isTrue,
      reason: 'getActiveCall 必须有真实业务调用方',
    );
  });

  test('验证3b：冷启动动作超龄（>30s）直接丢弃，不应用到当前通话', () async {
    final stale = FakeNativeChannel(readyResult: {
      'actions': [
        {
          'callId': 'call-stale',
          'action': 'answer',
          'at': DateTime.now()
              .subtract(const Duration(seconds: 45))
              .millisecondsSinceEpoch,
        }
      ],
    });
    final c4 = NativeCallCoordinator(
      calls: calls,
      onPresentIncoming: () {},
      channel: stale,
    );
    calls.addListener(c4.onCallPhaseChanged);
    await c4.restorePendingState();
    await pumpEventLoop();
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 0, reason: '过期动作必须丢弃');
  });

  test('验证7：通话结束 → 状态回报 ended 且待接听清理', () async {
    backend.ring();
    await pumpEventLoop();
    backend.events.add(const CallBackendEvent.ended());
    await pumpEventLoop();

    expect(calls.state.phase, CallPhase.ended);
    expect(channel.reportStates, contains('ended'), reason: '原生层按通话维度收到状态回报');
  });

  test('原生通知[拒绝] → 对响铃通话执行一次 reject', () async {
    backend.ring();
    await pumpEventLoop();
    await coordinator.handleNativeMessage('callRejected', {'callId': 'call-1'});
    expect(backend.rejects, 1);
    expect(calls.state.phase, CallPhase.ended);
  });

  test('原生呈现结束不拒绝仍有效的 Matrix 来电', () async {
    backend.ring();
    await pumpEventLoop();
    await coordinator.handleNativeMessage('callEnded', {'callId': 'call-1'});
    expect(backend.rejects, 0);
    expect(calls.state.phase, CallPhase.ringing);
  });

  for (final connected in [false, true]) {
    test(
        'presentation cleanup preserves ${connected ? 'connected' : 'connecting'} call',
        () async {
      await coordinator
          .handleNativeMessage('incomingCall', {'callId': 'current'});
      backend.ring();
      await pumpEventLoop();
      await coordinator
          .handleNativeMessage('callAccepted', {'callId': 'current'});
      if (connected) {
        backend.events.add(const CallBackendEvent.connected());
        await pumpEventLoop();
      }
      await coordinator.handleNativeMessage('callEnded', {'callId': 'current'});
      expect(backend.hangups, 0);
      expect(calls.state.phase,
          connected ? CallPhase.connected : CallPhase.connecting);
    });

    test(
        'explicit native termination ends ${connected ? 'connected' : 'connecting'} call',
        () async {
      await coordinator
          .handleNativeMessage('incomingCall', {'callId': 'current'});
      backend.ring();
      await pumpEventLoop();
      await coordinator
          .handleNativeMessage('callAccepted', {'callId': 'current'});
      if (connected) {
        backend.events.add(const CallBackendEvent.connected());
        await pumpEventLoop();
      }
      await coordinator
          .handleNativeMessage('callRejected', {'callId': 'current'});
      expect(backend.hangups, 1);
      expect(calls.state.phase, CallPhase.ended);
    });
  }

  for (final method in ['callAccepted', 'callRejected', 'callEnded']) {
    test('stale $method cannot act on a new presentation', () async {
      await coordinator.handleNativeMessage('incomingCall', {'callId': 'old'});
      await coordinator
          .handleNativeMessage('incomingCall', {'callId': 'current'});
      backend.ring();
      await pumpEventLoop();
      await coordinator.handleNativeMessage(method, {'callId': 'old'});
      expect(backend.accepts, 0);
      expect(backend.rejects, 0);
      expect(backend.hangups, 0);
      expect(calls.state.phase, CallPhase.ringing);
    });
  }

  test('old cleanup preserves new pending answer', () async {
    await coordinator
        .handleNativeMessage('incomingCall', {'callId': 'current'});
    await coordinator
        .handleNativeMessage('callAccepted', {'callId': 'current'});
    await coordinator.handleNativeMessage('callEnded', {'callId': 'old'});
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 1);
  });

  test('late action for a dismissed presentation cannot end active media',
      () async {
    await coordinator
        .handleNativeMessage('incomingCall', {'callId': 'current'});
    backend.ring();
    await pumpEventLoop();
    await coordinator
        .handleNativeMessage('callAccepted', {'callId': 'current'});
    await coordinator.handleNativeMessage('callEnded', {'callId': 'current'});
    await coordinator.handleNativeMessage('callRejected', {'callId': 'old'});
    expect(backend.hangups, 0);
    expect(calls.state.phase, CallPhase.connecting);
  });

  test('native hangup cancels permission-waiting accept continuation',
      () async {
    final permission = FakePermissions()..pending = Completer<bool>();
    final waitingCalls = CallController(
      backend: backend,
      permissions: permission,
      alerts: NoopAlerts(),
    );
    addTearDown(waitingCalls.dispose);
    final waiting = NativeCallCoordinator(
      calls: waitingCalls,
      onPresentIncoming: () {},
      channel: channel,
    );
    backend.ring();
    await pumpEventLoop();
    final accepting =
        waiting.handleNativeMessage('callAccepted', {'callId': 'current'});
    await pumpEventLoop();
    expect(waitingCalls.state.phase, CallPhase.requestingPermission);
    await waiting.handleNativeMessage('callRejected', {'callId': 'current'});
    permission.pending!.complete(true);
    await accepting;
    expect(backend.accepts, 0);
    expect(waitingCalls.state.phase, CallPhase.ended);
  });

  test('new presentation reopens actions after the previous presentation ended',
      () async {
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'old'});
    await coordinator.handleNativeMessage('callEnded', {'callId': 'old'});
    await coordinator
        .handleNativeMessage('incomingCall', {'callId': 'current'});
    backend.ring();
    await pumpEventLoop();
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'old'});
    expect(backend.accepts, 0);
    await coordinator
        .handleNativeMessage('callAccepted', {'callId': 'current'});
    expect(backend.accepts, 1);
  });

  test(
      'late action for the ended presentation cannot accept the next Matrix call',
      () async {
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'old'});
    backend.ring();
    await pumpEventLoop();
    backend.events.add(const CallBackendEvent.ended());
    await pumpEventLoop();
    backend.ring();
    await pumpEventLoop();
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'old'});
    expect(backend.accepts, 0);
    expect(calls.state.phase, CallPhase.ringing);
  });

  test('会话结束（dispose）→ 清空待接听并通知原生清理', () async {
    await coordinator.handleNativeMessage('incomingCall', {'callId': 'call-x'});
    await coordinator.handleNativeMessage('callAccepted', {'callId': 'call-x'});
    await coordinator.dispose();
    expect(channel.invocations.any((e) => e.$1 == 'endCall'), isTrue,
        reason: '登出/账号变化要通知原生清理呈现');
    // dispose 后响铃到达不再自动接听。
    backend.ring();
    await pumpEventLoop();
    expect(backend.accepts, 0);
  });
}
