import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
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
  bool connectedBeforeAttach = false;
  bool endedBeforeAttach = false;
  @override
  CallState get state => endedBeforeAttach
      ? CallState.kEnded
      : connectedBeforeAttach
          ? CallState.kConnected
          : super.state;
  @override
  Future<void> answer({String? txid}) => answerPending.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'), (_) async => null);
  test('late subscription observes connected snapshot only once', () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = DeferredCall(backend.voip,
        Room(id: '!test:example.test', client: client), 'fast-answer')
      ..connectedBeforeAttach = true;
    final events = <app.CallBackendEvent>[];
    final subscription = backend.callEvents.listen(events.add);
    await backend.delegate.handleNewCall(call);
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
    final call = DeferredCall(backend.voip,
        Room(id: '!test:example.test', client: client), 'fast-end')
      ..endedBeforeAttach = true;
    await backend.delegate.handleNewCall(call);
    expect(backend.hasActiveSession, isFalse);
    await backend.dispose();
  });
  test(
      'late answer from ended call cannot create connected event for replacement call',
      () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final room = Room(id: '!test:example.test', client: client);
    final first = DeferredCall(backend.voip, room, 'first');
    final second = DeferredCall(backend.voip, room, 'second');
    second.pc = ConnectedPeer();
    final events = <app.CallBackendEvent>[];
    final subscription = backend.callEvents.listen(events.add);
    await backend.delegate.handleNewCall(first);
    final answering = backend.accept();
    await backend.delegate.handleCallEnded(first);
    await backend.delegate.handleNewCall(second);
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
