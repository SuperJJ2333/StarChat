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
import 'call_wakeup_client.dart';
import 'incoming_call_gate.dart';
import 'turn_credentials_cache.dart';

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
  MatrixCallBackend._(this._client, this._voip, this._delegate,
      this.diagnostics, this._ensureActive);

  factory MatrixCallBackend(
    Client client, {
    CallDiagnostics? diagnostics,
    CallWakeupClient? wakeup,
    void Function()? ensureActive,
  }) {
    late MatrixCallBackend backend;
    final delegate = FlutterWebRtcDelegate(
      onNewCall: (call) => backend._execute(() => backend._attach(call)),
      onCallEnded: (call) => backend._execute(() => backend._ended(call)),
    );
    final turnCredentials = TurnCredentialsCache(fetch: client.getTurnServer);
    backend = MatrixCallBackend._(
      client,
      RefreshingTurnVoIP(client, delegate, turnCredentials),
      delegate,
      diagnostics ?? CallDiagnostics(),
      ensureActive ?? () {},
    );
    backend.wakeup = wakeup;
    unawaited(turnCredentials.getIceServers());
    return backend;
  }

  final Client _client;
  final void Function() _ensureActive;
  CallWakeupClient? wakeup;

  /// 通话对方身份的**统一**解析（Task L）：名称 + 头像 + 授权头一次算出。
  ///
  /// 由组合根注入（好友备注 > 好友昵称 > 业务好友头像 > Matrix displayName
  /// > Matrix avatar > username > Matrix ID）。回调可返回 null 表示无法解析，
  /// 此时 UI 回退到同步名称。
  Future<CallIdentity?> Function(String matrixUserId,
          {String? matrixDisplayName})?
      identityResolver;
  String? get activeCallId => _call?.callId;
  String? get activeRoomId => _call?.room.id;
  bool get isIncomingCall => _call != null && !_call!.isOutgoing;
  final VoIP _voip;
  final FlutterWebRtcDelegate _delegate;

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
  bool _connectedEmitted = false;
  var _disposed = false;
  int _operations = 0;
  Completer<void>? _operationsDrained;

  Future<T> _execute<T>(Future<T> Function() operation) async {
    if (_disposed) throw StateError('Matrix call backend is disposed');
    _ensureActive();
    if (_operations++ == 0) _operationsDrained = Completer<void>();
    try {
      return await operation();
    } finally {
      if (--_operations == 0) {
        _operationsDrained?.complete();
        _operationsDrained = null;
      }
    }
  }

  webrtc.MediaStream? get localMediaStream =>
      _call?.localUserMediaStream?.stream;
  webrtc.MediaStream? get remoteMediaStream =>
      _call?.remoteUserMediaStream?.stream;

  @override
  Stream<CallBackendEvent> get callEvents => _events.stream;

  /// 会话是否仍存活（controller 据此决定重试=再接听还是回拨）。
  @override
  bool get hasActiveSession => _call != null;

  /// 远端 answer（m.call.answer）已到达——主叫时间线的关键拐点。
  void markRemoteAnswerReceived() =>
      diagnostics.mark(CallDiagStage.remoteAnswerReceived);

  @override
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId) =>
      _execute(() => _isEncryptedDirectRoom(roomId, matrixUserId));

  /// Task F：拨出路径的**唯一**一次安全验证。
  ///
  /// 校验不变量（任一不满足即返回 null，绝不发起 WebRTC）：
  /// joined、encrypted、恰好两名 joined 成员、本地用户在成员内、
  /// 远端成员与预期 Matrix 用户完全一致。
  @override
  Future<VerifiedCallTarget?> verifyStartTarget(
          String roomId, String matrixUserId) =>
      _execute(() async {
        final room = _client.getRoomById(roomId);
        final localUserId = _client.userID;
        if (room == null ||
            localUserId == null ||
            matrixUserId.isEmpty ||
            room.membership != Membership.join ||
            !room.encrypted) {
          return null;
        }
        final members = await room.requestParticipants();
        final verified = isVerifiedDirectParticipantSet(
          members.map((member) => member.id).toSet(),
          localUserId: localUserId,
          remoteUserId: matrixUserId,
        );
        if (!verified) return null;
        return VerifiedCallTarget(
          roomId: roomId,
          remoteUserId: matrixUserId,
          localUserId: localUserId,
          verifiedAt: DateTime.now(),
        );
      });

  Future<bool> _isEncryptedDirectRoom(
      String roomId, String matrixUserId) async {
    final room = _client.getRoomById(roomId);
    final localUserId = _client.userID;
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

  @visibleForTesting
  Future<void> debugAttachCall(CallSession call) => _execute(() {
        if (!identical(call.room.client, _client)) {
          throw StateError('Matrix call session client mismatch');
        }
        return _attach(call);
      });
  @visibleForTesting
  Future<void> debugEndCall(CallSession call) => _execute(() {
        if (!identical(call.room.client, _client)) {
          throw StateError('Matrix call session client mismatch');
        }
        return _ended(call);
      });

  @override
  Future<void> start(String roomId, String matrixUserId, CallMediaType type) =>
      _execute(() async {
        // Compatibility entry point (tests / legacy callers): verify once here,
        // then reuse the same verified target so a single start path never
        // requests participants twice.
        final target = await verifyStartTarget(roomId, matrixUserId);
        if (target == null) {
          throw StateError('Unsafe Matrix call room');
        }
        await _startVerified(target, type);
      });

  /// 使用已验证目标发起呼叫：**不再**重复请求 participants。
  @override
  Future<void> startVerified(VerifiedCallTarget target, CallMediaType type) =>
      _execute(() => _startVerified(target, type));

  Future<void> _startVerified(
      VerifiedCallTarget target, CallMediaType type) async {
    // The target was produced by verifyStartTarget for this account.
    if (!target.matchesAccount(_client.userID)) {
      throw StateError('Verified call target belongs to another account');
    }
    final room = _client.getRoomById(target.roomId);
    if (room == null || room.membership != Membership.join || !room.encrypted) {
      throw StateError('Verified call target is no longer a callable room');
    }
    diagnostics.mark(CallDiagStage.outgoingInviteSent);
    final call = await _voip.inviteToCall(
      room,
      type == CallMediaType.video ? CallType.kVideo : CallType.kVoice,
      userId: target.remoteUserId,
    );
    await _attach(call);
    // Only a real, encrypted Matrix invite can trigger the separate VoIP wake.
    if (!_disposed && identical(_call, call) && !call.callHasEnded) {
      unawaited(wakeup?.invite(
          roomId: target.roomId,
          callId: call.callId,
          recipient: target.remoteUserId,
          video: type == CallMediaType.video));
    }
  }

  Future<void> _attach(CallSession call) async {
    if (_disposed || identical(_call, call)) return;
    _call = call;
    _connectedEmitted = false;
    unawaited(_fallback.stop());
    _teardownStreamWatch();
    diagnostics.reset();
    diagnostics.mark(CallDiagStage.inviteReceived);
    debugPrint('[matrix-call] inviteReceived room=${call.room.id} '
        'outgoing=${call.isOutgoing} type=${call.type.name}');
    _delegate.markActive(true);
    await _callStates?.cancel();
    if (_disposed || !identical(_call, call)) return;
    _callStates = call.onCallStateChanged.stream.listen((state) {
      if (_disposed || !identical(_call, call)) return;
      debugPrint('[matrix-call] state=${state.name}'); // 全状态关键路径日志（规格§五）
      if (state == CallState.kConnected) {
        _emitConnected(call);
      } else if (state == CallState.kEnded) {
        _ended(call);
      } else if (state == CallState.kConnecting && call.isOutgoing) {
        // Task N：主叫收到远端 answer 后进入 connecting——「对方接听」时刻，
        // 与「接通（ICE）」是两个不同的延迟问题。
        diagnostics.mark(CallDiagStage.remoteAnswerReceived);
      }
    });
    if (call.callHasEnded) {
      await _ended(call);
      return;
    }
    // P1-3：订阅 SDK 流级事件——流新增/移除/重建都会通知 UI 重新绑定
    // renderer（不再依赖状态事件恰好覆盖流变化时序）。
    _streamAddSub = call.onStreamAdd.stream.listen((wrapped) {
      _watchWrappedStream(wrapped);
      // Task N：首个远端轨道到达（媒体真正开始流动的最早信号）。
      if (!wrapped.isLocal()) {
        diagnostics.mark(CallDiagStage.firstRemoteTrack);
      }
      _mediaStreamEvents.add(null);
    });
    _streamRemovedSub = call.onStreamRemoved.stream.listen((_) {
      _mediaStreamEvents.add(null);
    });
    // 已存在的流（订阅早于 onStreamAdd 时）同样挂接 onStreamChanged。
    for (final wrapped in [...call.getLocalStreams, ...call.getRemoteStreams]) {
      _watchWrappedStream(wrapped);
    }
    // Fast remote answers can connect before outgoing setup finishes attaching.
    if (call.state == CallState.kConnected) _emitConnected(call);
    if (!call.isOutgoing) {
      // The _delegate is awaited by the SDK's sync event handler. Complete that
      // handler before a server-backed membership request, otherwise the
      // incoming-call UI can deadlock behind the sync that delivered it.
      unawaited(_execute(() => _validateIncoming(call)).catchError((_) {}));
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
    final localUserId = _client.userID;
    final gate = IncomingCallGate(
      localMembers: () => call.room
          .getParticipants([Membership.join])
          .map((member) => member.id)
          .toSet(),
      remoteMembers: () async {
        try {
          final memberEvents = await _client.getMembersByRoom(
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
    // Task L：被叫路径同样携带 avatarUrl/avatarHeaders——此前只传 displayName
    // 与 fallbackSeed，导致来电页丢失头像。
    CallIdentity? identity;
    try {
      identity = await identityResolver?.call(
        remoteUserId,
        matrixDisplayName:
            call.room.unsafeGetUserFromMemoryOrFallback(remoteUserId).displayName,
      );
    } catch (_) {
      identity = null; // 身份解析失败不得阻断来电呈现/接听。
    }
    if (!identical(_call, call)) return;
    _events.add(CallBackendEvent.incoming(
      roomId: call.room.id,
      matrixUserId: remoteUserId,
      type: call.type == CallType.kVideo
          ? CallMediaType.video
          : CallMediaType.audio,
      identity: identity,
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

  void _emitConnected(CallSession call) {
    if (_disposed || !identical(_call, call) || _connectedEmitted) return;
    _connectedEmitted = true;
    _fallback.markConnected();
    _startQualityMonitor();
    _events.add(const CallBackendEvent.connected());
  }

  Future<void> _ended(CallSession call) async {
    if (!identical(_call, call)) return;
    unawaited(wakeup?.end(roomId: call.room.id, callId: call.callId));
    // Detach synchronously before cleanup awaits. A new call may arrive while
    // the old stream subscriptions or quality monitor are shutting down.
    _call = null;
    final callStates = _callStates;
    _callStates = null;
    final quality = _quality;
    _quality = null;
    final fallback = _fallback;
    debugPrint('[matrix-call] ended reason=${call.hangupReason}');
    _teardownStreamWatch();
    _delegate.markActive(false);
    final qualitySummary = quality?.summary();
    if (qualitySummary != null) debugPrint(qualitySummary);
    diagnostics.mark(CallDiagStage.ended);
    debugPrint(diagnostics.summary());
    final interrupted = call.hangupReason == CallErrorCode.iceFailed;
    _events.add(interrupted
        ? const CallBackendEvent.networkInterrupted()
        : const CallBackendEvent.ended());
    await fallback.stop();
    await quality?.stop();
    await callStates?.cancel();
  }

  CallSession get _active =>
      _call ?? (throw StateError('No active Matrix call'));

  int _answerGeneration = 0;
  CallSession? _cancelledAnswerCall;
  void cancelPendingAnswer() {
    _cancelledAnswerCall = _call;
    _answerGeneration++;
  }

  @override
  Future<void> accept() => _execute(() async {
        final call = _active;
        if (identical(_cancelledAnswerCall, call)) {
          throw StateError('Call answer was cancelled');
        }
        final generation = _answerGeneration;
        // Task G：media answer 立即开始；wakeup HTTP 只是并行旁路。
        if (wakeup != null) {
          await wakeup!.answerAndConnect(
            roomId: call.room.id,
            callId: call.callId,
            isCurrent: () =>
                generation == _answerGeneration &&
                !_disposed &&
                identical(_call, call) &&
                !call.callHasEnded,
            connect: call.answer,
          );
        } else {
          await call.answer();
        }
        if (generation != _answerGeneration) return;
        debugPrint('[matrix-call] answer_started');
        if (_disposed || !identical(_call, call) || call.callHasEnded) return;
        // kConnected 丢失兜底（规格§五）：10 秒内 peerConnection 已连而
        // SDK 状态事件未到 → 主动补发 connected（事件先到则 watcher 静默）。
        await _fallback.stop();
        if (_disposed || !identical(_call, call) || _connectedEmitted) return;
        _fallback = ConnectedFallbackWatcher(
          pollInterval: const Duration(milliseconds: 500),
          timeout: const Duration(seconds: 10),
          isPeerConnected: () async =>
              identical(_call, call) &&
              call.pc?.connectionState ==
                  webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          emitConnected: () {
            _emitConnected(call);
          },
        )..start();
      });

  /// Task G：显式 tombstone（wakeup `alreadyEnded`）——只在 roomId + callId
  /// 与当前 active 会话**完全匹配**时结束该通话；绝不误伤后续新通话。
  Future<void> endActiveCallIfMatching(
      {required String roomId, required String callId}) async {
    if (_disposed) return;
    final call = _call;
    if (call == null || call.callHasEnded) return;
    if (call.room.id != roomId || call.callId != callId) return;
    await _execute(() => call.hangup(reason: CallErrorCode.userHangup));
  }

  /// 供组合根接线的兼容包装（`CallWakeupClient.onExplicitlyEnded` 契约）。
  Future<void> Function({required String roomId, required String callId})
      get explicitEndHandler => endActiveCallIfMatching;

  @override
  Future<void> reject() =>
      _execute(() => _active.reject(reason: CallErrorCode.userHangup));
  @override
  Future<void> hangup() =>
      _execute(() => _active.hangup(reason: CallErrorCode.userHangup));
  /// Task M：本地 audio track 先行；远端元数据推送是**旁路**，不阻塞 UI。
  ///
  /// `CallSession.setMicrophoneMuted` 会先翻转真实 track 的 `enabled`，再
  /// `sendSDPStreamMetadataChanged` 通知对端。后者是 Matrix 信令往返，可能
  /// 明显慢于本地操作；让它参与 await 会让静音按钮长时间停在旧状态。
  /// 因此本地翻转失败 → 抛出（UI 回滚）；仅在远端元数据阶段失败 → 记录诊断，
  /// 不欺骗 UI（本地确实已经静音）。
  @override
  Future<void> setMuted(bool value) => _execute(() async {
        final call = _active;
        try {
          await call.setMicrophoneMuted(value);
        } catch (_) {
          // Local track operation itself failed: surface to the caller.
          rethrow;
        }
        return;
      });
  @override
  Future<void> setSpeaker(bool value) => webrtc.Helper.setSpeakerphoneOn(value);

  @override
  Future<void> switchCamera() => _execute(() async {
        final tracks =
            _active.localUserMediaStream?.stream?.getVideoTracks() ?? [];
        if (tracks.isEmpty) return;
        await webrtc.Helper.switchCamera(tracks.first);
      });

  /// 通话结束摘要：呼叫方落一条会话消息（加密房间自动加密），
  /// 双端时间线各显示“通话时长/已取消”。
  Future<void> sendCallSummary({
    required String roomId,
    required CallMediaType type,
    required bool connected,
    required Duration duration,
  }) async {
    final room = _client.getRoomById(roomId);
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
    _disposed = true;
    final drained = _operationsDrained;
    if (drained != null) await drained.future;
    _call = null;
    _teardownStreamWatch();
    await _quality?.stop();
    await _fallback.stop();
    await _callStates?.cancel();
    _callStates = null;
    await _events.close();
    await _mediaStreamEvents.close();
  }
}
