import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:matrix/matrix.dart' hide CallBackend;
import 'package:webrtc_interface/webrtc_interface.dart' as rtc_interface;
import 'package:webrtc_interface/webrtc_interface.dart' show MediaStream;

import 'call_connected_fallback.dart';
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

  /// P1-3（gallery-call-review）：媒体流变化事件（本地/远端流新增、
  /// 移除或重建）。渲染绑定不再只依赖通话状态通知——流在状态事件之后
  /// 到达/重建时，UI 也能及时拿到新 srcObject。
  final _mediaStreamEvents = StreamController<void>.broadcast();
  StreamSubscription<WrappedMediaStream>? _streamAddSub;
  StreamSubscription<WrappedMediaStream>? _streamRemovedSub;
  final _streamChangedSubs = <StreamSubscription<MediaStream>>[];

  /// 媒体流变化广播（UI 订阅后应在每次事件重取 local/remoteMediaStream）。
  Stream<void> get mediaStreamChanges => _mediaStreamEvents.stream;

  /// kConnected 丢失兜底（accept 后 10s 内 peer 已连则补发）。
  ConnectedFallbackWatcher _fallback = ConnectedFallbackWatcher(
    pollInterval: const Duration(milliseconds: 500),
    timeout: const Duration(seconds: 10),
    isPeerConnected: () async => false,
    emitConnected: () {},
  );
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
    _teardownStreamWatch();
    diagnostics.reset();
    diagnostics.mark(CallDiagStage.inviteReceived);
    debugPrint('[matrix-call] inviteReceived room=${call.room.id} '
        'outgoing=${call.isOutgoing} type=${call.type.name}');
    delegate.markActive(true);
    await _callStates?.cancel();
    _callStates = call.onCallStateChanged.stream.listen((state) {
      debugPrint('[matrix-call] state=${state.name}'); // 全状态关键路径日志（规格§五）
      if (state == CallState.kConnected) {
        // 兜底已补发过 connected → SDK 事件迟到，去重不重发。
        final alreadyEmitted = _fallback.didEmit;
        _fallback.markConnected();
        if (alreadyEmitted) {
          debugPrint('[matrix-call] connected dedup (fallback already emitted)');
          return;
        }
        _startQualityMonitor();
        _events.add(const CallBackendEvent.connected());
        debugPrint('[matrix-call] connected (sdk event)');
      } else if (state == CallState.kEnded) {
        _ended(call);
      }
    });
    // P1-3：订阅 SDK 流级事件——流新增/移除/重建都会通知 UI 重新绑定
    // renderer（不再依赖状态事件恰好覆盖流变化时序）。
    _streamAddSub = call.onStreamAdd.stream.listen((wrapped) {
      _watchWrappedStream(wrapped);
      _mediaStreamEvents.add(null);
    });
    _streamRemovedSub = call.onStreamRemoved.stream.listen((_) {
      _mediaStreamEvents.add(null);
    });
    // 已存在的流（订阅早于 onStreamAdd 时）同样挂接 onStreamChanged。
    for (final wrapped in [...call.getLocalStreams, ...call.getRemoteStreams]) {
      _watchWrappedStream(wrapped);
    }
    if (!call.isOutgoing) {
      // The delegate is awaited by the SDK's sync event handler. Complete that
      // handler before any further work so the incoming-call UI is never
      // blocked behind the sync that delivered it.
      unawaited(_validateIncoming(call));
    }
  }

  void _watchWrappedStream(WrappedMediaStream wrapped) {
    // track 重挂会触发 WrappedMediaStream.onStreamChanged（新 MediaStream
    // 实例）——据此通知 UI 换绑 renderer 的 srcObject。
    _streamChangedSubs.add(wrapped.onStreamChanged.stream.listen((_) {
      _mediaStreamEvents.add(null);
    }));
  }

  void _teardownStreamWatch() {
    unawaited(_streamAddSub?.cancel());
    _streamAddSub = null;
    unawaited(_streamRemovedSub?.cancel());
    _streamRemovedSub = null;
    for (final sub in _streamChangedSubs) {
      unawaited(sub.cancel());
    }
    _streamChangedSubs.clear();
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
    debugPrint('[matrix-call] ended reason=${call.hangupReason}');
    _teardownStreamWatch();
    await _fallback.stop();
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
  Future<void> accept() async {
    debugPrint('[matrix-call] answerSent (accept)');
    await _active.answer();
    // kConnected 丢失兜底（规格§五）：10 秒内 peerConnection 已连而
    // SDK 状态事件未到 → 主动补发 connected（事件先到则 watcher 静默）。
    await _fallback.stop();
    _fallback = ConnectedFallbackWatcher(
      pollInterval: const Duration(milliseconds: 500),
      timeout: const Duration(seconds: 10),
      isPeerConnected: () async =>
          _call?.pc?.connectionState ==
          webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      emitConnected: () {
        _startQualityMonitor();
        _events.add(const CallBackendEvent.connected());
      },
    )..start();
  }
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
    _teardownStreamWatch();
    await _fallback.stop();
    await _callStates?.cancel();
    await _events.close();
    await _mediaStreamEvents.close();
  }
}
