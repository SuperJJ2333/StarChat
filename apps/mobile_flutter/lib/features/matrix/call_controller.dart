import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/performance_trace.dart';
import 'call_alerts.dart';
import 'call_audio_route_coordinator.dart';
import 'call_diagnostics.dart';
import '../../core/notification/sound_type.dart';

/// 主叫无人接听的自动取消时长（微信语义：约 60 秒后提示无应答）。
const callRingTimeout = Duration(seconds: 60);

/// 被叫接听后的连接超时：到点 ICE 未接通 → 失败态（可重试）。
/// 此前 ICE 不通会永远停留在响铃界面（SDK 无 kConnecting 超时）。
const callConnectTimeout = Duration(seconds: 45);

/// 通话时长展示格式：mm:ss（超 1 小时 h:mm:ss）。
String formatCallDuration(Duration duration) {
  final total = duration.inSeconds.clamp(0, 24 * 3600);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '${two(minutes)}:${two(seconds)}';
}

enum CallMediaType { audio, video }

enum CallPhase {
  idle,
  requestingPermission,
  ringing,

  /// 已接听/已拨出，等待 ICE 接通（超时进 failed 可重试）。
  connecting,
  connected,
  permissionDenied,
  ended,
  failed,
}

enum CallBackendEventKind {
  incoming,
  signalingReady,
  connected,
  ended,
  networkInterrupted,
}

/// 通话对方身份的统一呈现模型（Task L）。
///
/// 名称与头像**必须**来自同一套解析，避免「名称用好友备注、头像却用 Matrix
/// ID」这类不一致。`avatarUrl` + `avatarHeaders` 由
/// [MatrixAvatarUrlResolver] 生成（含授权头）；**禁止**把 `mxc://` 直接当
/// 普通 HTTP URL，也禁止把头像 URL 放进推送 payload。
@immutable
final class CallIdentity {
  const CallIdentity({
    required this.matrixUserId,
    required this.displayName,
    required this.fallbackSeed,
    this.avatarUrl,
    this.avatarHeaders = const {},
    this.avatarIsMatrixMedia = false,
  });

  final String matrixUserId;
  final String displayName;

  /// 首字回退种子（avatar 未就绪时立即显示，不留空白圆圈）。
  final String fallbackSeed;

  /// 已解析、可直接请求的头像 URL（业务头像或 Matrix 缩略图 URL）。
  final String? avatarUrl;

  /// 请求 [avatarUrl] 所需的授权头（Matrix 认证媒体）。
  final Map<String, String> avatarHeaders;

  /// [avatarUrl] 是否来自 Matrix 媒体（`mxc://` 解析后的缩略图 URL）。
  final bool avatarIsMatrixMedia;

  CallIdentity copyWith({
    String? displayName,
    String? avatarUrl,
    Map<String, String>? avatarHeaders,
    bool? avatarIsMatrixMedia,
  }) =>
      CallIdentity(
        matrixUserId: matrixUserId,
        displayName: displayName ?? this.displayName,
        fallbackSeed: fallbackSeed,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        avatarHeaders: avatarHeaders ?? this.avatarHeaders,
        avatarIsMatrixMedia: avatarIsMatrixMedia ?? this.avatarIsMatrixMedia,
      );

  @override
  bool operator ==(Object other) =>
      other is CallIdentity &&
      other.matrixUserId == matrixUserId &&
      other.displayName == displayName &&
      other.fallbackSeed == fallbackSeed &&
      other.avatarUrl == avatarUrl &&
      other.avatarIsMatrixMedia == avatarIsMatrixMedia &&
      mapEquals(other.avatarHeaders, avatarHeaders);

  @override
  int get hashCode => Object.hash(
      matrixUserId,
      displayName,
      fallbackSeed,
      avatarUrl,
      avatarIsMatrixMedia,
      Object.hashAllUnordered(avatarHeaders.entries));
}

/// 已通过安全验证的拨出目标（Task F）。
///
/// 由 [CallBackend.verifyStartTarget] 产出、[CallBackend.startVerified] 消费；
/// 只承载 opaque 通话元数据，不含任何媒体或明文。
@immutable
final class VerifiedCallTarget {
  const VerifiedCallTarget({
    required this.roomId,
    required this.remoteUserId,
    this.localUserId,
    this.verifiedAt,
  });

  final String roomId;

  /// 已与房间成员集合核对过的远端 Matrix 用户。
  final String remoteUserId;

  /// 验证时的本地用户（账号切换后可用于判定目标过期）。
  final String? localUserId;

  /// 验证时刻（诊断/过期判定用）。
  final DateTime? verifiedAt;

  /// 目标仍属于当前账号。
  bool matchesAccount(String? currentUserId) =>
      localUserId == null ||
      currentUserId == null ||
      localUserId == currentUserId;

  @override
  String toString() => 'VerifiedCallTarget(roomId=$roomId, '
      'remoteUserId=$remoteUserId)';
}

final class CallBackendEvent {
  const CallBackendEvent.signalingReady()
      : kind = CallBackendEventKind.signalingReady,
        roomId = null,
        matrixUserId = null,
        type = null,
        identity = null;
  const CallBackendEvent.connected()
      : kind = CallBackendEventKind.connected,
        roomId = null,
        matrixUserId = null,
        type = null,
        identity = null;
  const CallBackendEvent.ended()
      : kind = CallBackendEventKind.ended,
        roomId = null,
        matrixUserId = null,
        type = null,
        identity = null;
  const CallBackendEvent.networkInterrupted()
      : kind = CallBackendEventKind.networkInterrupted,
        roomId = null,
        matrixUserId = null,
        type = null,
        identity = null;
  const CallBackendEvent.incoming({
    required this.roomId,
    required this.matrixUserId,
    required this.type,
    this.identity,
  }) : kind = CallBackendEventKind.incoming;

  final CallBackendEventKind kind;
  final String? roomId;
  final String? matrixUserId;
  final CallMediaType? type;

  /// 来电对方的统一身份呈现（可选：解析失败时页面回退到同步名称）。
  final CallIdentity? identity;
}

abstract interface class CallPermissionGateway {
  Future<bool> request({required bool video});
}

abstract interface class CallBackend {
  Stream<CallBackendEvent> get callEvents;
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId);

  /// 拨出前的**唯一**一次安全验证（Task F）。
  ///
  /// 返回 null 表示该目标不是「已加入 + 已加密 + 恰好两名成员 + 本地用户
  /// 在成员内 + 远端与预期 Matrix 用户一致」的可信双人加密房间。
  ///
  /// 验证结果通过 [VerifiedCallTarget] 传递给 [startVerified]，使同一次
  /// `start` 路径不再重复调用 `room.requestParticipants()`。
  Future<VerifiedCallTarget?> verifyStartTarget(
      String roomId, String matrixUserId);

  /// 使用已通过安全验证的 [VerifiedCallTarget] 发起呼叫。
  ///
  /// 实现方**不得**在此再次请求 participants——验证已在
  /// [verifyStartTarget] 完成。
  Future<void> startVerified(VerifiedCallTarget target, CallMediaType type);

  Future<void> start(String roomId, String matrixUserId, CallMediaType type);
  Future<void> accept();
  Future<void> reject();
  Future<void> hangup();
  Future<void> setMuted(bool value);
  Future<void> setSpeaker(bool value);
  Future<void> switchCamera();

  /// 会话是否仍存活（接听失败重试时：存活→再接听，已死→回拨）。
  bool get hasActiveSession;
}

final class CallViewState {
  const CallViewState(
    this.phase, {
    this.type,
    this.roomId,
    this.matrixUserId,
    this.muted = false,
    this.speaker = false,
    this.message,
    this.connectedAt,
    this.identity,
  });
  final CallPhase phase;
  final CallMediaType? type;
  final String? roomId;
  final String? matrixUserId;
  final bool muted;
  final bool speaker;
  final String? message;

  /// 接通时刻：页面据此实时展示通话时长。
  final DateTime? connectedAt;

  /// 对方统一身份呈现（名称 + 头像 + 授权头）；null 时页面自行回退。
  final CallIdentity? identity;

  CallViewState copyWith({
    CallPhase? phase,
    bool? muted,
    bool? speaker,
    String? message,
    DateTime? connectedAt,
    CallIdentity? identity,
    bool clearConnectedAt = false,
    bool clearMessage = false,
  }) =>
      CallViewState(
        phase ?? this.phase,
        type: type,
        roomId: roomId,
        matrixUserId: matrixUserId,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
        message: clearMessage ? null : (message ?? this.message),
        connectedAt:
            clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
        identity: identity ?? this.identity,
      );
}

final class CallController extends ChangeNotifier {
  CallController({
    required this.backend,
    required this.permissions,
    CallAlerts? alerts,
    CallSoundCues? soundCues,
    CallDiagnostics? diagnostics,
    CallAudioRouteCoordinator? audioRoute,
    PerformanceTraceRecorder? performanceRecorder,
    this.ringTimeout = callRingTimeout,
    this.connectTimeout = callConnectTimeout,
    DateTime Function()? now,
  })  : alerts = alerts ?? CallAlerts(),
        soundCues = soundCues ?? const NotificationSystemCallSoundCues(),
        diagnostics = diagnostics ?? CallDiagnostics(),
        audioRoute =
            audioRoute ?? CallAudioRouteCoordinator(apply: backend.setSpeaker),
        _performanceRecorder =
            performanceRecorder ?? PerformanceTraceRecorder.instance,
        _now = now ?? DateTime.now {
    _events = backend.callEvents.listen(_handleEvent);
  }

  /// 接通时刻时钟（测试注入 fake clock；协议与信令不使用）。
  final DateTime Function() _now;

  /// 当前时刻（与 connectedAt 同源；UI 计时展示用）。
  DateTime now() => _now();

  final CallBackend backend;
  final CallPermissionGateway permissions;
  final CallAlerts alerts;

  /// 接通/结束提示音（PRD §5）。
  final CallSoundCues soundCues;

  /// 关键路径耗时诊断（与 backend 共享同一实例/时间线）。
  final CallDiagnostics diagnostics;

  /// **唯一**音频路由所有者（Task I）：任何 speaker/earpiece 决策只经此组件。
  final CallAudioRouteCoordinator audioRoute;
  final PerformanceTraceRecorder _performanceRecorder;
  PerformanceTrace? _callSetupTrace;

  /// 主叫等待超时：到点未接通自动挂断并提示。
  final Duration ringTimeout;

  /// 被叫接听后的连接超时：到点 ICE 未接通 → failed（可重试）。
  final Duration connectTimeout;

  late final StreamSubscription<CallBackendEvent> _events;
  Timer? _ringTimeoutTimer;
  Timer? _connectTimeoutTimer;
  CallViewState state = const CallViewState(CallPhase.idle);
  bool _incomingRinging = false;
  int _callGeneration = 0;
  bool _disposed = false;

  bool _isCurrent(int generation) =>
      !_disposed && generation == _callGeneration;

  void _beginCallSetup() {
    _finishCallSetup(PerformanceResult.cancelled);
    if (!_performanceRecorder.recordingEnabled) return;
    _callSetupTrace = _performanceRecorder
        .start(PerformanceOperationType.callSetup)
      ..mark(PerformanceStage.callStart);
  }

  void _finishCallSetup(PerformanceResult result) {
    final trace = _callSetupTrace;
    _callSetupTrace = null;
    trace?.finish(result: result);
  }

  Future<void> start({
    required String roomId,
    required String matrixUserId,
    required CallMediaType type,
  }) async {
    if (_disposed) return;
    _beginCallSetup();
    final generation = ++_callGeneration;
    _ringTimeoutTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    audioRoute.reset();
    _muteDesired = false;
    _muteOperation = null;
    _set(CallViewState(
      CallPhase.requestingPermission,
      roomId: roomId,
      matrixUserId: matrixUserId,
      type: type,
    ));
    diagnostics.mark(CallDiagStage.outgoingStart);
    // Task F：唯一一次安全验证，结果直接交给 startVerified 复用。
    VerifiedCallTarget? target;
    try {
      target = await backend.verifyStartTarget(roomId, matrixUserId);
    } catch (_) {
      if (_isCurrent(generation)) _finishCallSetup(PerformanceResult.failed);
      rethrow;
    }
    if (!_isCurrent(generation)) return;
    diagnostics.mark(CallDiagStage.securityValidated);
    if (target == null) {
      _set(
          state.copyWith(phase: CallPhase.failed, message: '只能在已验证的加密双人会话中通话'));
      throw StateError('Call room is not an encrypted direct room');
    }
    bool allowed;
    try {
      allowed = await permissions.request(video: type == CallMediaType.video);
    } catch (_) {
      if (_isCurrent(generation)) _finishCallSetup(PerformanceResult.failed);
      rethrow;
    }
    if (!_isCurrent(generation)) return;
    if (!allowed) {
      _set(state.copyWith(
          phase: CallPhase.permissionDenied, message: '需要麦克风和摄像头权限'));
      return;
    }
    try {
      // 唯一路由所有者：媒体建立前先清场（上一通遗留的免提/视频默认）。
      await audioRoute.applyPreMediaRoute(type);
      if (!_isCurrent(generation)) return;
      diagnostics.mark(CallDiagStage.mediaAcquireStarted);
      await backend.startVerified(target, type);
      if (!_isCurrent(generation) || state.phase == CallPhase.connected) return;
      diagnostics.mark(CallDiagStage.mediaAcquireReady);
      _incomingRinging = false; // 主叫：等待音。
      _set(state.copyWith(phase: CallPhase.ringing));
      _armRingTimeout();
    } catch (_) {
      if (!_isCurrent(generation) || state.phase == CallPhase.connected) return;
      alerts.stop();
      _set(state.copyWith(phase: CallPhase.failed, message: '呼叫失败，请重试'));
      rethrow;
    }
  }

  /// PRD §9/§10：被叫按语音/视频各自铃声，主叫用呼叫等待音。
  SoundType _ringtoneForState() {
    if (!_incomingRinging) return SoundType.callOutgoing;
    return state.type == CallMediaType.video
        ? SoundType.callVideoIncoming
        : SoundType.callVoiceIncoming;
  }

  /// 主叫无人接听：超时自动挂断（不再等待，提示无应答）。
  void _armRingTimeout() {
    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = Timer(ringTimeout, () async {
      if (state.phase != CallPhase.ringing) return;
      await _safeHangup();
      _set(state.copyWith(phase: CallPhase.ended, message: '对方无应答，已取消'));
    });
  }

  Future<void> _safeHangup() async {
    try {
      await backend.hangup();
    } catch (_) {
      // 挂断失败也按结束处理，避免界面卡死。
    }
  }

  /// 权限不足保留来电；信令异常不再裸抛（此前无 try/catch，
  /// ICE 不通则永远停在响铃界面）——进入 failed 可重试；
  /// 接听后进入 connecting 并布防连接超时。
  Future<void> accept() async {
    if (_disposed ||
        (state.phase != CallPhase.ringing && state.phase != CallPhase.failed)) {
      return;
    }
    final generation = _callGeneration;
    final type = state.type ?? CallMediaType.audio;
    _beginCallSetup();
    diagnostics.mark(CallDiagStage.answerTapped);
    _set(state.copyWith(
        phase: CallPhase.requestingPermission, clearMessage: true));
    // 注意：接听**不是**新通话，绝不能重置路由偏好——用户在响铃期间点过
    // 「免提」必须保留到接通之后（Task I：用户选择优先于自动策略）。
    try {
      final allowed =
          await permissions.request(video: type == CallMediaType.video);
      if (!_isCurrent(generation)) return;
      if (!allowed) {
        _finishCallSetup(PerformanceResult.rejected);
        _set(state.copyWith(
            phase: CallPhase.ringing,
            message:
                type == CallMediaType.video ? '请授权麦克风和摄像头后接听' : '请授权麦克风后接听'));
        return;
      }
      diagnostics.mark(CallDiagStage.permissionGranted);
      _incomingRinging = false;
      _set(state.copyWith(phase: CallPhase.connecting));
      // The answer itself can stall while preparing media or sending signaling.
      _armConnectTimeout();
      // 唯一路由所有者：接听前先清场。路由失败不得阻断已授权的接听。
      try {
        await audioRoute.applyPreMediaRoute(type);
      } catch (_) {
        // 音频路由异常不影响接听本身（回音/路由问题单独诊断）。
      }
      if (!_isCurrent(generation) || state.phase != CallPhase.connecting) {
        return;
      }
      diagnostics.mark(CallDiagStage.answerStarted);
      await backend.accept();
      if (!_isCurrent(generation)) return;
      diagnostics.mark(CallDiagStage.answerSent);
    } catch (_) {
      if (_isCurrent(generation) && state.phase != CallPhase.connected) {
        _acceptFailed('接听失败，请重试');
      }
    }
  }

  /// 接听失败/连接超时后的重试：会话仍存活 → 守卫再接听；
  /// 会话已死（超时挂断/信令终止）→ 对同一用户回拨（等价新呼叫）。
  Future<void> retryAfterFailure() async {
    if (state.phase != CallPhase.failed) return;
    final roomId = state.roomId;
    final matrixUserId = state.matrixUserId;
    final type = state.type ?? CallMediaType.audio;
    if (roomId == null || matrixUserId == null) return;
    if (backend.hasActiveSession) {
      await accept();
      return;
    }
    await start(roomId: roomId, matrixUserId: matrixUserId, type: type);
  }

  void _acceptFailed(String message) {
    alerts.stop();
    _connectTimeoutTimer?.cancel();
    _set(state.copyWith(phase: CallPhase.failed, message: message));
  }

  void _armConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    final generation = _callGeneration;
    _connectTimeoutTimer = Timer(connectTimeout, () async {
      if (!_isCurrent(generation) || state.phase != CallPhase.connecting) {
        return;
      }
      _acceptFailed('接通超时，请重试');
      await _safeHangup();
    });
  }

  Future<void> _safeReject() async {
    try {
      await backend.reject();
    } catch (_) {
      // 拒绝失败也按已拒接处理，避免界面卡死。
    }
  }

  Future<void> reject() async {
    if (_disposed) return;
    _set(state.copyWith(phase: CallPhase.ended, message: '已拒接'));
    unawaited(_safeReject());
  }

  Future<void> hangup() async {
    if (_disposed) return;
    _set(state.copyWith(phase: CallPhase.ended, message: '通话已结束'));
    unawaited(_safeHangup());
  }

  /// 用户期望的静音状态（串行化意图，独立于已落地的媒体状态）。
  ///
  /// **始终**反映用户最后一次意图；媒体是否真的翻转由后端诚实报告。
  bool _muteDesired = false;
  bool get muted => state.muted;

  /// 静音串行化：本地 track 先行，UI 立即反映真实媒体状态。
  ///
  /// Task M 修复的竞态：快速双击时两次 `toggleMute` 会读到同一个旧
  /// `state.muted`（false/false → 都下发 true）。这里改为**同步**翻转
  /// 期望值并串行执行，最终媒体状态必然收敛到用户最后一次意图。
  Future<void> toggleMute() {
    // 同步翻转意图：并发调用不会读到同一个旧值。
    _muteDesired = !_muteDesired;
    return _muteOperation ??= _runMuteOperations();
  }

  /// 设定静音（幂等；与 [CallViewState.muted] 一致的真实 audio track 状态）。
  ///
  /// 已经处于目标状态时直接返回：重复的相同意图（CallKit 重放、UI 重建）
  /// 不会再次下发平台调用。
  Future<void> setMuted(bool value) {
    if (state.muted == value && _muteDesired == value) {
      return Future<void>.value();
    }
    _muteDesired = value;
    return _muteOperation ??= _runMuteOperations();
  }

  Future<void>? _muteOperation;

  Future<void> _runMuteOperations() async {
    try {
      var lastApplied = state.muted;
      while (!_disposed) {
        final desired = _muteDesired;
        final generation = _callGeneration;
        try {
          await backend.setMuted(desired);
        } catch (_) {
          // 本地 track 操作失败：UI 必须回滚，不得永久骗人。
          if (_disposed || !_isCurrent(generation)) return;
          _set(state.copyWith(muted: !desired));
          return;
        }
        if (_disposed || !_isCurrent(generation)) return;
        _set(state.copyWith(muted: desired));
        if (_muteDesired == desired) return; // 已收敛到最新意图
        if (desired == lastApplied) {
          // 后端未真正改变媒体状态：继续重试只会死循环。
          // 保持真实媒体状态（不欺骗 UI），并留诊断。
          assert(() {
            debugPrint('[chatflow/call] mute backend did not change state '
                'for desired=$desired');
            return true;
          }());
          return;
        }
        lastApplied = desired;
      }
    } finally {
      _muteOperation = null;
    }
  }

  Future<void> toggleSpeaker() async {
    final type = state.type ?? CallMediaType.audio;
    final speaker = !audioRoute.speaker;
    _set(state.copyWith(speaker: speaker));
    try {
      // markUserPreference: 这是用户的**明确选择**，此后自动策略
      // （接通默认、媒体流重建、ICE restart）一律不得覆盖。
      await audioRoute.setSpeaker(speaker,
          type: type, markUserPreference: true);
      if (_disposed) return;
      _set(state.copyWith(speaker: audioRoute.speaker));
    } catch (_) {
      if (_disposed) return;
      _set(state.copyWith(speaker: audioRoute.speaker));
    }
  }

  Future<void> switchCamera() => backend.switchCamera();

  Future<void> _handleEvent(CallBackendEvent event) async {
    if (_disposed) return;
    switch (event.kind) {
      case CallBackendEventKind.incoming:
        _finishCallSetup(PerformanceResult.cancelled);
        _callGeneration++;
        _incomingRinging = true;
        _muteDesired = false; // 新通话：静音意图以新会话的真实状态为起点
        _muteOperation = null;
        diagnostics.mark(CallDiagStage.incomingUiShown);
        _set(CallViewState(
          CallPhase.ringing,
          roomId: event.roomId,
          matrixUserId: event.matrixUserId,
          type: event.type,
          identity: event.identity,
        ));
      case CallBackendEventKind.signalingReady:
        if (state.phase != CallPhase.ended &&
            state.phase != CallPhase.failed &&
            state.phase != CallPhase.permissionDenied) {
          _callSetupTrace?.mark(PerformanceStage.signalingReady);
        }
      case CallBackendEventKind.connected:
        if (state.phase == CallPhase.ended ||
            state.phase == CallPhase.failed ||
            state.phase == CallPhase.permissionDenied) {
          return;
        }
        final generation = _callGeneration;
        _incomingRinging = false;
        diagnostics.mark(CallDiagStage.iceConnected);
        _callSetupTrace?.mark(PerformanceStage.iceConnected);
        // 接通即停铃；视频通话默认打开免提（微信语义），语音保持听筒。
        alerts.stop();
        _ringTimeoutTimer?.cancel();
        _connectTimeoutTimer?.cancel();
        final type = state.type ?? CallMediaType.audio;
        // UI connection must not depend on a platform audio-route Future.
        _set(state.copyWith(
          phase: CallPhase.connected,
          connectedAt: _now(),
        ));
        _callSetupTrace?.mark(PerformanceStage.callConnected);
        _finishCallSetup(PerformanceResult.success);
        // 唯一路由所有者按产品语义应用默认；用户显式选择优先。
        try {
          await audioRoute.preferForConnected(type);
          if (_isCurrent(generation)) {
            _set(state.copyWith(speaker: audioRoute.speaker));
          }
        } catch (_) {
          // 免提切换失败不影响接通。
        }
      case CallBackendEventKind.ended:
        // Cleanup of a failed call must keep its explanation and retry action.
        if (state.phase == CallPhase.failed ||
            state.phase == CallPhase.permissionDenied) {
          return;
        }
        _set(state.copyWith(phase: CallPhase.ended, message: '通话已结束'));
      case CallBackendEventKind.networkInterrupted:
        _finishCallSetup(PerformanceResult.failed);
        _set(state.copyWith(phase: CallPhase.ended, message: '网络中断，通话已结束'));
    }
  }

  void _set(CallViewState next) {
    if (_disposed) return;
    if (next.phase == CallPhase.ended ||
        next.phase == CallPhase.failed ||
        next.phase == CallPhase.permissionDenied) {
      _finishCallSetup(switch (next.phase) {
        CallPhase.failed => PerformanceResult.failed,
        CallPhase.permissionDenied => PerformanceResult.rejected,
        _ => PerformanceResult.cancelled,
      });
      _callGeneration++;
      _ringTimeoutTimer?.cancel();
      _connectTimeoutTimer?.cancel();
    }
    final previousPhase = state.phase;
    state = next;
    // 响铃阶段维持提醒；接通/结束/失败等其余状态一律停铃。
    if (next.phase == CallPhase.ringing) {
      alerts.start(_ringtoneForState());
    } else if (previousPhase == CallPhase.ringing &&
        next.phase != CallPhase.ringing) {
      alerts.stop();
    }
    // PRD §5：接通确认音与结束音（经统一通知系统）。
    if (next.phase == CallPhase.connected &&
        previousPhase != CallPhase.connected) {
      soundCues.connected();
    } else if (next.phase == CallPhase.ended &&
        previousPhase != CallPhase.ended) {
      soundCues.ended();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _callSetupTrace?.dispose();
    _callSetupTrace = null;
    _callGeneration++;
    _ringTimeoutTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    alerts.stop();
    _events.cancel();
    super.dispose();
  }
}
