import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/voip/models/call_options.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_call_adapter.dart';
import 'call_adapter_lifecycle_test.dart' show OfflineClient;

class CameraTrack implements MediaStreamTrack {
  CameraTrack(this.id, this.kind);
  @override
  final String id;
  @override
  final String kind;
  bool stopped = false;
  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  bool enabled = true;
  @override
  Map<String, dynamic> getSettings() => {'facingMode': 'user'};
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraStream implements MediaStream {
  CameraStream(this.video, this.audio);
  MediaStreamTrack video;
  final CameraTrack audio;
  @override
  List<MediaStreamTrack> getVideoTracks() => [video];
  @override
  Future<void> addTrack(MediaStreamTrack track,
      {bool addToNative = true}) async {
    video = track;
  }

  @override
  Future<void> removeTrack(MediaStreamTrack track,
      {bool removeFromNative = true}) async {}
  @override
  List<MediaStreamTrack> getAudioTracks() => [audio];
  @override
  List<MediaStreamTrack> getTracks() => [audio, video];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraSender implements RTCRtpSender {
  CameraSender(this.track);
  @override
  MediaStreamTrack? track;
  bool fail = false;
  @override
  Future<void> replaceTrack(MediaStreamTrack? value) async {
    if (fail) throw StateError('native sender failure');
    track = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraPeer implements RTCPeerConnection {
  CameraPeer(this.localSenders);
  final List<RTCRtpSender> localSenders;
  @override
  Future<List<RTCRtpSender>> getSenders() async => localSenders;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraWrapped implements WrappedMediaStream {
  CameraWrapped(this.stream);
  @override
  final MediaStream stream;
  bool muted = false;
  @override
  bool isVideoMuted() => muted;
  @override
  final onStreamChanged = CachedStreamController<MediaStream>();
  @override
  void setVideoMuted(bool value) {
    muted = value;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class CameraCall extends CallSession {
  CameraCall(VoIP voip, Room room, this.localUserMediaStream)
      : super(CallOptions(
            callId: 'camera-call',
            type: CallType.kVideo,
            dir: CallDirection.kOutgoing,
            room: room,
            voip: voip,
            localPartyId: 'party',
            iceServers: []));
  @override
  final WrappedMediaStream localUserMediaStream;
  @override
  List<WrappedMediaStream> get getLocalStreams => [];
  @override
  List<WrappedMediaStream> get getRemoteStreams => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('camera off detaches only video sender and stops camera capture',
      () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final video = CameraTrack('camera', 'video');
    final audio = CameraTrack('microphone', 'audio');
    final videoSender = CameraSender(video);
    final audioSender = CameraSender(audio);
    final wrapped = CameraWrapped(CameraStream(video, audio));
    final call = CameraCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!room:example.test', client: client),
        wrapped)
      ..pc = CameraPeer([videoSender, audioSender]);
    await backend.debugAttachCall(call);
    await backend.setCameraEnabled(false);
    expect(videoSender.track, isNull);
    expect(video.stopped, isTrue);
    expect(audioSender.track, audio);
    expect(audio.stopped, isFalse);
    expect(audio.enabled, isTrue);
    await backend.dispose();
  });
  test('camera resume reacquires video only and replaces the stopped track',
      () async {
    final nativeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'),
            (call) async {
      nativeCalls.add(call);
      if (call.method == 'getUserMedia') {
        return {
          'streamId': 'replacement-camera',
          'audioTracks': [],
          'videoTracks': [
            {
              'id': 'new-camera',
              'kind': 'video',
              'label': 'camera',
              'enabled': true,
              'settings': {}
            }
          ],
        };
      }
      return null;
    });
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final video = CameraTrack('camera', 'video');
    final audio = CameraTrack('microphone', 'audio');
    final sender = CameraSender(video);
    final stream = CameraStream(video, audio);
    final call = CameraCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!room:example.test', client: client),
        CameraWrapped(stream))
      ..pc = CameraPeer([sender, CameraSender(audio)]);
    await backend.debugAttachCall(call);
    await backend.setCameraEnabled(false);
    await backend.setCameraEnabled(true);
    expect(sender.track?.id, 'new-camera');
    expect(stream.video.id, 'new-camera');
    final acquired =
        nativeCalls.singleWhere((call) => call.method == 'getUserMedia');
    expect((acquired.arguments as Map)['constraints']['audio'], isFalse);
    expect(audio.stopped, isFalse);
    expect(audio.enabled, isTrue);
    await backend.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null);
  });
  test('camera sender failure keeps video and audio intact', () async {
    final client = OfflineClient();
    final backend = MatrixCallBackend(client);
    final video = CameraTrack('camera', 'video');
    final audio = CameraTrack('microphone', 'audio');
    final sender = CameraSender(video)..fail = true;
    final wrapped = CameraWrapped(CameraStream(video, audio));
    final call = CameraCall(
        VoIP(
            client,
            FlutterWebRtcDelegate(
                onNewCall: (_) async {}, onCallEnded: (_) async {})),
        Room(id: '!room:example.test', client: client),
        wrapped)
      ..pc = CameraPeer([sender, CameraSender(audio)]);
    await backend.debugAttachCall(call);
    await expectLater(backend.setCameraEnabled(false), throwsStateError);
    expect(video.stopped, isFalse);
    expect(sender.track, video);
    expect(wrapped.muted, isFalse);
    expect(audio.stopped, isFalse);
    await backend.dispose();
  });
}
