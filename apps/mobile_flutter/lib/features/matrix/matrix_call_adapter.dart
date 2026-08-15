import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart' hide CallBackend;
import 'package:webrtc_interface/webrtc_interface.dart' as rtc_interface;

import 'call_controller.dart';

bool isVerifiedDirectParticipantSet(
  Set<String> participantIds, {
  required String localUserId,
  required String remoteUserId,
}) =>
    participantIds.length == 2 &&
    participantIds.contains(localUserId) &&
    participantIds.contains(remoteUserId);

String? resolveIncomingRemoteParticipant(
  Set<String> participantIds, {
  required String localUserId,
  String? advertisedRemoteUserId,
}) {
  final remote = participantIds.where((id) => id != localUserId).toList();
  if (participantIds.length != 2 || remote.length != 1) return null;
  if (advertisedRemoteUserId != null &&
      advertisedRemoteUserId != remote.single) {
    return null;
  }
  return remote.single;
}

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
  ]) {
    assert(() {
      final servers = configuration['iceServers'] as List<dynamic>? ?? const [];
      final urls = servers
          .whereType<Map<dynamic, dynamic>>()
          .map((server) => server['urls'])
          .toList(growable: false);
      debugPrint('[Call] ICE server URLs configured: $urls');
      return true;
    }());
    return webrtc.createPeerConnection(configuration, constraints);
  }

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

  webrtc.MediaStream? get localMediaStream =>
      _call?.localUserMediaStream?.stream;
  webrtc.MediaStream? get remoteMediaStream =>
      _call?.remoteUserMediaStream?.stream;

  @override
  Stream<CallBackendEvent> get callEvents => _events.stream;

  @override
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId) async {
    final room = client.getRoomById(roomId);
    final localUserId = client.userID;
    if (room == null ||
        localUserId == null ||
        room.membership != Membership.join ||
        !room.encrypted) {
      return false;
    }
    final members = await room.requestParticipants();
    return isVerifiedDirectParticipantSet(
      members.map((member) => member.id).toSet(),
      localUserId: localUserId,
      remoteUserId: matrixUserId,
    );
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
      // The delegate is awaited by the SDK's sync event handler. Complete that
      // handler before a server-backed membership request, otherwise the
      // incoming-call UI can deadlock behind the sync that delivered it.
      unawaited(_validateIncoming(call));
    }
  }

  Future<void> _validateIncoming(CallSession call) async {
    await Future<void>.delayed(Duration.zero);
    final localUserId = client.userID;
    final memberEvents = await client.getMembersByRoom(
          call.room.id,
          membership: Membership.join,
        ) ??
        const <MatrixEvent>[];
    if (!identical(_call, call)) return;
    final participantIds =
        memberEvents.map((event) => event.stateKey).whereType<String>().toSet();
    final remoteUserId = localUserId == null
        ? null
        : resolveIncomingRemoteParticipant(
            participantIds,
            localUserId: localUserId,
            advertisedRemoteUserId: call.remoteUserId,
          );
    if (localUserId == null ||
        call.room.membership != Membership.join ||
        !call.room.encrypted ||
        remoteUserId == null ||
        !isVerifiedDirectParticipantSet(
          participantIds,
          localUserId: localUserId,
          remoteUserId: remoteUserId,
        )) {
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
