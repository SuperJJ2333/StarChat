import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart' hide CallBackend;
import 'package:webrtc_interface/webrtc_interface.dart' as rtc_interface;

import 'call_controller.dart';

final class WebRtcPermissionGateway implements CallPermissionGateway {
  const WebRtcPermissionGateway();

  @override
  Future<bool> request({required bool video}) async {
    try {
      final stream = await webrtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video ? {'facingMode': 'user'} : false,
      });
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
      return true;
    } catch (_) {
      return false;
    }
  }
}

final class FlutterWebRtcDelegate implements WebRTCDelegate {
  FlutterWebRtcDelegate({
    required this.onNewCall,
    required this.onCallEnded,
  });

  final Future<void> Function(CallSession call) onNewCall;
  final Future<void> Function(CallSession call) onCallEnded;
  var _canHandleNewCall = true;

  @override
  bool get canHandleNewCall => _canHandleNewCall;
  void markActive(bool active) => _canHandleNewCall = !active;

  @override
  Future<rtc_interface.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) =>
      webrtc.createPeerConnection(configuration, constraints);

  @override
  rtc_interface.MediaDevices get mediaDevices => webrtc.navigator.mediaDevices;
  @override
  bool get isWeb => false;
  @override
  EncryptionKeyProvider? get keyProvider => null;

  @override
  Future<void> playRingtone() => SystemSound.play(SystemSoundType.alert);
  @override
  Future<void> stopRingtone() async {}
  @override
  Future<void> handleNewCall(CallSession session) => onNewCall(session);
  @override
  Future<void> handleCallEnded(CallSession session) => onCallEnded(session);
  @override
  Future<void> handleMissedCall(CallSession session) => onCallEnded(session);
  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}
  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}
}

final class MatrixCallBackend implements CallBackend {
  MatrixCallBackend._(this.client, this.voip, this.delegate);

  factory MatrixCallBackend(Client client) {
    late MatrixCallBackend backend;
    final delegate = FlutterWebRtcDelegate(
      onNewCall: (call) => backend._attach(call),
      onCallEnded: (call) => backend._ended(call),
    );
    backend = MatrixCallBackend._(client, VoIP(client, delegate), delegate);
    return backend;
  }

  final Client client;
  final VoIP voip;
  final FlutterWebRtcDelegate delegate;
  final _events = StreamController<CallBackendEvent>.broadcast();
  StreamSubscription<CallState>? _callStates;
  CallSession? _call;

  @override
  Stream<CallBackendEvent> get callEvents => _events.stream;

  @override
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId) async {
    final room = client.getRoomById(roomId);
    if (room == null ||
        room.membership != Membership.join ||
        !room.encrypted ||
        !room.isDirectChat ||
        room.directChatMatrixID != matrixUserId) {
      return false;
    }
    final members = await room.requestParticipants();
    return members.length == 2;
  }

  @override
  Future<void> start(
      String roomId, String matrixUserId, CallMediaType type) async {
    if (!await isEncryptedDirectRoom(roomId, matrixUserId)) {
      throw StateError('Unsafe Matrix call room');
    }
    final room = client.getRoomById(roomId)!;
    final call = await voip.inviteToCall(
      room,
      type == CallMediaType.video ? CallType.kVideo : CallType.kVoice,
      userId: matrixUserId,
    );
    await _attach(call);
  }

  Future<void> _attach(CallSession call) async {
    if (identical(_call, call)) return;
    _call = call;
    delegate.markActive(true);
    await _callStates?.cancel();
    _callStates = call.onCallStateChanged.stream.listen((state) {
      if (state == CallState.kConnected) {
        _events.add(const CallBackendEvent.connected());
      } else if (state == CallState.kEnded) {
        _ended(call);
      }
    });
    if (!call.isOutgoing) {
      final remoteUserId = call.remoteUserId ?? call.room.directChatMatrixID;
      if (remoteUserId == null ||
          !await isEncryptedDirectRoom(call.room.id, remoteUserId)) {
        await call.reject(reason: CallErrorCode.userHangup);
        return;
      }
      _events.add(CallBackendEvent.incoming(
        roomId: call.room.id,
        matrixUserId: remoteUserId,
        type: call.type == CallType.kVideo
            ? CallMediaType.video
            : CallMediaType.audio,
      ));
    }
  }

  Future<void> _ended(CallSession call) async {
    if (!identical(_call, call)) return;
    delegate.markActive(false);
    final interrupted = call.hangupReason == CallErrorCode.iceFailed;
    _events.add(interrupted
        ? const CallBackendEvent.networkInterrupted()
        : const CallBackendEvent.ended());
    _call = null;
    await _callStates?.cancel();
    _callStates = null;
  }

  CallSession get _active =>
      _call ?? (throw StateError('No active Matrix call'));

  @override
  Future<void> accept() => _active.answer();
  @override
  Future<void> reject() => _active.reject(reason: CallErrorCode.userHangup);
  @override
  Future<void> hangup() => _active.hangup(reason: CallErrorCode.userHangup);
  @override
  Future<void> setMuted(bool value) => _active.setMicrophoneMuted(value);
  @override
  Future<void> setSpeaker(bool value) => webrtc.Helper.setSpeakerphoneOn(value);

  @override
  Future<void> switchCamera() async {
    final tracks = _active.localUserMediaStream?.stream?.getVideoTracks() ?? [];
    if (tracks.isEmpty) return;
    await webrtc.Helper.switchCamera(tracks.first);
  }

  Future<void> dispose() async {
    await _callStates?.cancel();
    await _events.close();
  }
}
