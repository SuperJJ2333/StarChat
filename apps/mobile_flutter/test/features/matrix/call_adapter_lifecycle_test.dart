import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/features/matrix/call_wakeup_client.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_call_adapter.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart' as app;

class OfflineClient extends Client {
  OfflineClient() : super('call-lifecycle-test');
  @override
  Future<TurnServerCredentials> getTurnServer() =>
      Future.error(StateError('offline'));
}

class ConnectedPeer implements RTCPeerConnection {
  @override
  RTCPeerConnectionState get connectionState =>
      RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class DeferredCall extends CallSession {
  DeferredCall(VoIP voip, Room room, String id)
      : super(CallOptions(
          callId: id,
          type: CallType.kVoice,
          dir: CallDirection.kOutgoing,
          room: room,
          voip: voip,
          localPartyId: 'test-party',
          iceServers: [],
        ));
  final answerPending = Completer<void>();
  int answerCalls = 0;
  int rejectCalls = 0;
  @override
  Future<void> reject({CallErrorCode? reason, bool shouldEmit = true}) async {
    rejectCalls++;
    endedBeforeAttach = true;
  }

  bool connectedBeforeAttach = false;
  bool endedBeforeAttach = false;
  @override
  CallState get state => endedBeforeAttach
      ? CallState.kEnded
      : connectedBeforeAttach
          ? CallState.kConnected
          : super.state;
  @override
  Future<void> answer({String? txid}) {
    answerCalls++;
    return answerPending.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'), (_) async => null);
  test('cancel before backend admission persists for the same call session',
      () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!test:example.test', client: client),
        'cancelled-answer');
    await backend.debugAttachCall(call);
    backend.cancelPendingAnswer();
    await expectLater(backend.accept(), throwsStateError);
    expect(call.answerCalls, 0);
    await backend.dispose();
  });
  test(
      'wakeup service failure does not block an active encrypted call answer',
      () async {
    final client = OfflineClient();
    final wakeup = CallWakeupClient(
        baseUrl: Uri.parse('https://example.test/ios-call/'),
        accessToken: () => 'session',
        httpClient: MockClient((_) async => http.Response('{}', 503)));
    final backend = MatrixCallBackend(client, wakeup: wakeup);
    final call = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!test:example.test', client: client),
        'failed-claim');
    await backend.debugAttachCall(call);
    // Task G：wakeup API 只是尽力而为的旁路，绝不是 WebRTC 媒体建立的前置
    // 条件。`unavailable`(503) 不得阻断用户对已校验 Matrix 会话的明确接听；
    // 只有显式 `alreadyEnded`（tombstone）才允许结束该通话。
    //
    // The answer itself is deliberately left pending (DeferredCall): that is
    // exactly the "local media setup still running" window in which the old
    // implementation rejected the call. Assert the answer was started and no
    // rejection happened, then resolve the pending answer for cleanup.
    unawaited(backend.accept());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(call.answerCalls, 1,
        reason: 'wakeup 服务不可用不得阻断已校验会话的接听');
    expect(call.rejectCalls, 0,
        reason: '用户明确接听后不得因辅助服务失败而静默拒接');
    call.answerPending.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await backend.dispose();
  });
  test('late subscription observes connected snapshot only once', () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!test:example.test', client: client),
        'fast-answer')
      ..connectedBeforeAttach = true;
    final events = <app.CallBackendEvent>[];
    final subscription = backend.callEvents.listen(events.add);
    await backend.debugAttachCall(call);
    await Future<void>.delayed(Duration.zero);
    expect(
        events
            .where((event) => event.kind == app.CallBackendEventKind.connected),
        hasLength(1));
    call.onCallStateChanged.add(CallState.kConnected);
    await Future<void>.delayed(Duration.zero);
    expect(
        events
            .where((event) => event.kind == app.CallBackendEventKind.connected),
        hasLength(1));
    await subscription.cancel();
    await backend.dispose();
  });
  test('already ended call does not remain active after attachment', () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!test:example.test', client: client),
        'fast-end')
      ..endedBeforeAttach = true;
    await backend.debugAttachCall(call);
    expect(backend.hasActiveSession, isFalse);
    await backend.dispose();
  });
  test(
      'late answer from ended call cannot create connected event for replacement call',
      () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final room = Room(id: '!test:example.test', client: client);
    final first = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        room,
        'first');
    final second = DeferredCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        room,
        'second');
    second.pc = ConnectedPeer();
    final events = <app.CallBackendEvent>[];
    final subscription = backend.callEvents.listen(events.add);
    await backend.debugAttachCall(first);
    final answering = backend.accept();
    await backend.debugEndCall(first);
    await backend.debugAttachCall(second);
    events.clear();
    first.answerPending.complete();
    await answering;
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final connected = events
        .where((event) => event.kind == app.CallBackendEventKind.connected);
    expect(connected, isEmpty);
    await subscription.cancel();
    await backend.dispose();
  });
}
