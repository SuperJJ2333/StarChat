import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart' hide CallBackend;
import 'package:webrtc_interface/webrtc_interface.dart' as rtc_interface;

import 'call_controller.dart';
import 'call_diagnostics.dart';
import 'call_quality_monitor.dart';
import 'incoming_call_gate.dart';

/// 通话结束摘要消息的自定义 msgtype（同红包/转账的自定义消息模式）。
const changliaoCallMessageType = 'com.changliao.call';

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
  MatrixCallBackend._(this.client, this.voip, this.delegate, this.diagnostics);

  factory MatrixCallBackend(
    Client client, {
    CallDiagnostics? diagnostics,
  }) {
    late MatrixCallBackend backend;
    final delegate = FlutterWebRtcDelegate(
      onNewCall: (call) => backend._attach(call),
      onCallEnded: (call) => backend._ended(call),
    );
    backend = MatrixCallBackend._(
      client,
      VoIP(client, delegate),
      delegate,
      diagnostics ?? CallDiagnostics(),
    );
    return backend;
  }

  final Client client;
  final VoIP voip;
  final FlutterWebRtcDelegate delegate;

  /// 关键路径耗时诊断（与 CallController 共享同一实例/时间线）。
  final CallDiagnostics diagnostics;
  final _events = StreamController<CallBackendEvent>.broadcast();
  StreamSubscription<CallState>? _callStates;
  CallSession? _call;
  CallQualityMonitor? _quality;

  webrtc.MediaStream? get localMediaStream =>
      _call?.localUserMediaStream?.stream;
  webrtc.MediaStream? get remoteMediaStream =>
      _call?.remoteUserMediaStream?.stream;

  @override
  Stream<CallBackendEvent> get callEvents => _events.stream;

  /// 会话是否仍存活（controller 据此决定重试=再接听还是回拨）。
  @override
  bool get hasActiveSession => _call != null;

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
    diagnostics.reset();
    diagnostics.mark(CallDiagStage.inviteReceived);
    delegate.markActive(true);
    await _callStates?.cancel();
    _callStates = call.onCallStateChanged.stream.listen((state) {
      if (state == CallState.kConnected) {
        _startQualityMonitor();
        _events.add(const CallBackendEvent.connected());
      } else if (state == CallState.kEnded) {
        _ended(call);
      }
    });
    if (!call.isOutgoing) {
      // The delegate is awaited by the SDK's sync event handler. Complete that
      // handler before any further work so the incoming-call UI is never
      // blocked behind the sync that delivered it.
      unawaited(_validateIncoming(call));
    }
  }

  /// P0（来电不被服务器阻塞）：本地已同步成员优先——零网络请求放行
  /// 来电 UI；本地成员为空才回退服务器 /members（4s 超时，失败拒接，
  /// 与旧实现安全语义一致）。
  Future<void> _validateIncoming(CallSession call) async {
    await Future<void>.delayed(Duration.zero);
    final localUserId = client.userID;
    final gate = IncomingCallGate(
      localMembers: () => call.room
          .getParticipants([Membership.join])
          .map((member) => member.id)
          .toSet(),
      remoteMembers: () async {
        try {
          final memberEvents = await client.getMembersByRoom(
            call.room.id,
            membership: Membership.join,
          );
          return memberEvents
              ?.map((event) => event.stateKey)
              .whereType<String>()
              .toSet();
        } catch (_) {
          return null;
        }
      },
    );
    final remoteUserId = await gate.validate(
      localUserId: localUserId,
      advertisedRemoteUserId: call.remoteUserId,
      roomJoined: call.room.membership == Membership.join,
      roomEncrypted: call.room.encrypted,
    );
    if (!identical(_call, call)) return;
    // Gate 内部已完整校验（成员恰好双方、含本地用户、与信令声明一致、
    // 房间已 join 且加密）——与旧 resolveIncomingRemoteParticipant +
    // isVerifiedDirectParticipantSet 组合等价，本地/服务器成员来源同权。
    if (localUserId == null || remoteUserId == null) {
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

  void _startQualityMonitor() {
    _quality?.stop();
    final pc = _call?.pc;
    if (pc == null) return;
    _quality = CallQualityMonitor(
      getStats: () => pc.getStats(),
    )..start();
  }

  Future<void> _ended(CallSession call) async {
    if (!identical(_call, call)) return;
    delegate.markActive(false);
    await _quality?.stop();
    final qualitySummary = _quality?.summary();
    if (qualitySummary != null) debugPrint(qualitySummary);
    diagnostics.mark(CallDiagStage.ended);
    debugPrint(diagnostics.summary());
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

  /// 通话结束摘要：呼叫方落一条会话消息（加密房间自动加密），
  /// 双端时间线各显示“通话时长/已取消”。
  Future<void> sendCallSummary({
    required String roomId,
    required CallMediaType type,
    required bool connected,
    required Duration duration,
  }) async {
    final room = client.getRoomById(roomId);
    if (room == null) return;
    await room.sendEvent({
      'msgtype': changliaoCallMessageType,
      'body': connected
          ? (type == CallMediaType.video ? '[视频通话]' : '[语音通话]')
          : '已取消',
      'call_type': type == CallMediaType.video ? 'video' : 'voice',
      'call_connected': connected,
      'duration_ms': duration.inMilliseconds,
    });
  }

  Future<void> dispose() async {
    await _callStates?.cancel();
    await _events.close();
  }
}
