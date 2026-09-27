import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/call_controller.dart' as app;
import 'package:liuhetong_mobile/features/matrix/call_diagnostics.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_call_adapter.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';

final class _OfflineClient extends Client {
  _OfflineClient() : super('call-setup-signal-test');

  @override
  Future<TurnServerCredentials> getTurnServer() =>
      Future.error(StateError('offline'));
}

final class _Call extends CallSession {
  _Call(VoIP voip, Room room,
      {CallDirection direction = CallDirection.kOutgoing})
      : super(CallOptions(
          callId: 'local-test-call',
          type: CallType.kVoice,
          dir: direction,
          room: room,
          voip: voip,
          localPartyId: 'local-test-party',
          iceServers: [],
        ));

  final answerPending = Completer<void>();

  @override
  Future<void> answer({String? txid}) => answerPending.future;

  @override
  Future<void> reject({CallErrorCode? reason, bool shouldEmit = true}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('FlutterWebRTC.Event'), (_) async => null);

  test('remote answer emits signaling once, before the ICE connected event',
      () async {
    final client = _OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = _Call(
      VoIP(
          client,
          FlutterWebRtcDelegate(
              onNewCall: (_) async {}, onCallEnded: (_) async {})),
      Room(id: '!local:example.test', client: client),
    );
    final events = <app.CallBackendEventKind>[];
    final subscription = backend.callEvents.listen((event) {
      events.add(event.kind);
    });
    await backend.debugAttachCall(call);

    call.onCallStateChanged.add(CallState.kConnecting);
    await Future<void>.delayed(Duration.zero);
    expect(events, [app.CallBackendEventKind.signalingReady]);
    call.onCallStateChanged.add(CallState.kConnecting);
    call.onCallStateChanged.add(CallState.kConnected);
    await Future<void>.delayed(Duration.zero);
    expect(events, [
      app.CallBackendEventKind.signalingReady,
      app.CallBackendEventKind.connected,
    ]);

    await subscription.cancel();
    await backend.dispose();
  });

  test('incoming signaling waits for the actual answer Future', () async {
    final client = _OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = _Call(
      VoIP(
          client,
          FlutterWebRtcDelegate(
              onNewCall: (_) async {}, onCallEnded: (_) async {})),
      Room(id: '!local:example.test', client: client),
      direction: CallDirection.kIncoming,
    );
    final events = <app.CallBackendEventKind>[];
    final subscription = backend.callEvents.listen((event) {
      events.add(event.kind);
    });
    await backend.debugAttachCall(call);
    final accepting = backend.accept();
    await Future<void>.delayed(Duration.zero);
    expect(events, isNot(contains(app.CallBackendEventKind.signalingReady)));

    call.answerPending.complete();
    await accepting;
    await Future<void>.delayed(Duration.zero);
    expect(events, contains(app.CallBackendEventKind.signalingReady));

    await subscription.cancel();
    await backend.dispose();
  });

  test('call adapter debug output contains no room identifier', () async {
    final client = _OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = _Call(
      VoIP(
          client,
          FlutterWebRtcDelegate(
              onNewCall: (_) async {}, onCallEnded: (_) async {})),
      Room(id: '!private-room:example.test', client: client),
    );
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      await backend.debugAttachCall(call);
      expect(lines.join('\n'), isNot(contains('!private-room:example.test')));
    } finally {
      debugPrint = previous;
      await backend.dispose();
    }
  });

  test('call adapter end writes no detailed lines with diagnostics disabled',
      () async {
    final client = _OfflineClient();
    final backend = MatrixCallBackend(client);
    final call = _Call(
      VoIP(
          client,
          FlutterWebRtcDelegate(
              onNewCall: (_) async {}, onCallEnded: (_) async {})),
      Room(id: '!local:example.test', client: client),
    );
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      await backend.debugAttachCall(call);
      await backend.debugEndCall(call);
      // TURN discovery owns a separate legacy log; this assertion covers the
      // adapter and CallDiagnostics detail lines handled by this change.
      expect(
          lines.where((line) => !line.startsWith('[chatflow/turn]')), isEmpty);
    } finally {
      debugPrint = previous;
      await backend.dispose();
    }
  });

  test('diagnostic call adapter details use only the unified call tag',
      () async {
    final client = _OfflineClient();
    final backend =
        MatrixCallBackend(client, diagnostics: CallDiagnostics(log: (_) {}));
    final call = _Call(
      VoIP(
          client,
          FlutterWebRtcDelegate(
              onNewCall: (_) async {}, onCallEnded: (_) async {})),
      Room(id: '!local:example.test', client: client),
    );
    final previous = debugPrint;
    final lines = <String>[];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    try {
      await backend.debugAttachCall(call);
      await backend.debugEndCall(call);
      final callLines =
          lines.where((line) => !line.startsWith('[chatflow/turn]')).toList();
      expect(callLines, isNotEmpty);
      expect(callLines, everyElement(startsWith('[chatflow/call]')));
    } finally {
      debugPrint = previous;
      await backend.dispose();
    }
  });
}
