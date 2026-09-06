import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

class _Media implements MediaDevices {
  int requests = 0;
  Future<MediaStream> Function()? capture;
  Map<String, dynamic>? lastConstraints;
  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    requests++;
    lastConstraints = constraints;
    if (capture != null) return capture!();
    throw StateError('permission unavailable');
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Peer implements RTCPeerConnection {
  @override
  Future<RTCSessionDescription> createAnswer(
      [Map<String, dynamic>? constraints]) async {
    throw const _AnswerReached();
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _AnswerReached implements Exception {
  const _AnswerReached();
}

class _Stream implements MediaStream {
  bool disposed = false;
  @override
  List<MediaStreamTrack> getTracks() => [];
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Delegate implements WebRTCDelegate {
  final _Media media = _Media();
  Future<void> Function()? stop;
  @override
  MediaDevices get mediaDevices => media;
  @override
  Future<RTCPeerConnection> createPeerConnection(
          Map<String, dynamic> configuration,
          [Map<String, dynamic>? constraints]) async =>
      _Peer();
  @override
  Future<void> stopRingtone() async {
    await stop?.call();
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Call extends CallSession {
  _Call(VoIP voip, Room room, CallType type)
      : super(CallOptions(
            callId: 'incoming-test',
            type: type,
            dir: CallDirection.kIncoming,
            localPartyId: 'local-test',
            voip: voip,
            room: room,
            iceServers: []));
  int addedStreams = 0;
  @override
  Future<void> addLocalStream(MediaStream stream, String purpose,
      {bool addToPeerConnection = true}) async {
    addedStreams++;
  }

  @override
  Future<void> hangup(
      {required CallErrorCode reason, bool shouldEmit = true}) async {
    setCallState(CallState.kEnded);
  }
}

void extraTests() {
  for (final terminal in [CallState.kEnding, CallState.kEnded]) {
    testWidgets('answer captures once and releases late media after $terminal',
        (tester) async {
      final client = Client('incoming-late-media');
      final delegate = _Delegate();
      final capture = Completer<MediaStream>();
      delegate.media.capture = () => capture.future;
      final call = _Call(VoIP(client, delegate),
          Room(id: '!test:example.test', client: client), CallType.kVideo);
      await call.initWithInvite(CallType.kVideo,
          RTCSessionDescription('v=0\r\n', 'offer'), null, 60000, false);
      final first = call.answer();
      final second = call.answer();
      expect(identical(first, second), true);
      expect(delegate.media.requests, 1);
      call.setCallState(terminal);
      final stream = _Stream();
      capture.complete(stream);
      await first;
      expect(stream.disposed, true);
      expect(call.addedStreams, 0);
      await tester.pump(const Duration(seconds: 61));
    });
  }
  testWidgets('termination while stopping ringtone cannot resume answering',
      (tester) async {
    final client = Client('incoming-stop-race');
    final delegate = _Delegate();
    delegate.media.capture = () async => _Stream();
    final stopped = Completer<void>();
    delegate.stop = () => stopped.future;
    final call = _Call(VoIP(client, delegate),
        Room(id: '!test:example.test', client: client), CallType.kVoice);
    await call.initWithInvite(CallType.kVoice,
        RTCSessionDescription('v=0\r\n', 'offer'), null, 60000, false);
    final answering = call.answer();
    await tester.pump();
    call.setCallState(CallState.kEnded);
    stopped.complete();
    await answering;
    expect(call.state, CallState.kEnded);
    await tester.pump(const Duration(seconds: 61));
  });
  testWidgets('authorized voice answer attaches media before creating answer',
      (tester) async {
    final client = Client('incoming-authorized-media');
    final delegate = _Delegate();
    delegate.media.capture = () async => _Stream();
    final call = _Call(VoIP(client, delegate),
        Room(id: '!test:example.test', client: client), CallType.kVoice);
    await call.initWithInvite(CallType.kVoice,
        RTCSessionDescription('v=0\r\n', 'offer'), null, 60000, false);
    await expectLater(call.answer(), throwsA(isA<_AnswerReached>()));
    expect(delegate.media.requests, 1);
    expect(delegate.media.lastConstraints!['video'], false);
    expect(call.addedStreams, 1);
    expect(call.state, CallState.kCreateAnswer);
    call.setCallState(CallState.kEnded);
    await tester.pump(const Duration(seconds: 61));
  });
}

void main() {
  extraTests();
  for (final type in [CallType.kVoice, CallType.kVideo]) {
    testWidgets('$type rings without capture and denied answer remains ringing',
        (tester) async {
      final client = Client('incoming-permission-test');
      final delegate = _Delegate();
      final voip = VoIP(client, delegate);
      final call =
          _Call(voip, Room(id: '!test:example.test', client: client), type);
      await call.initWithInvite(
          type, RTCSessionDescription('v=0\r\n', 'offer'), null, 60000, false);
      expect(call.state, CallState.kRinging);
      expect(delegate.media.requests, 0);
      await expectLater(call.answer(), throwsStateError);
      expect(delegate.media.requests, 1);
      expect(call.state, CallState.kRinging);
      call.setCallState(CallState.kEnded);
      await tester.pump(const Duration(seconds: 61));
    });
  }
}
