import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_alerts.dart';
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

enum CallBackendEventKind { incoming, connected, ended, networkInterrupted }

final class CallBackendEvent {
  const CallBackendEvent.connected()
      : kind = CallBackendEventKind.connected,
        roomId = null,
        matrixUserId = null,
        type = null;
  const CallBackendEvent.ended()
      : kind = CallBackendEventKind.ended,
        roomId = null,
        matrixUserId = null,
        type = null;
  const CallBackendEvent.networkInterrupted()
      : kind = CallBackendEventKind.networkInterrupted,
        roomId = null,
        matrixUserId = null,
        type = null;
  const CallBackendEvent.incoming({
    required this.roomId,
    required this.matrixUserId,
    required this.type,
  }) : kind = CallBackendEventKind.incoming;

  final CallBackendEventKind kind;
  final String? roomId;
  final String? matrixUserId;
  final CallMediaType? type;
}

abstract interface class CallPermissionGateway {
  Future<bool> request({required bool video});
}

abstract interface class CallBackend {
  Stream<CallBackendEvent> get callEvents;
  Future<bool> isEncryptedDirectRoom(String roomId, String matrixUserId);
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

  CallViewState copyWith({
    CallPhase? phase,
    bool? muted,
    bool? speaker,
    String? message,
    DateTime? connectedAt,
    bool clearConnectedAt = false,
  }) =>
      CallViewState(
        phase ?? this.phase,
        type: type,
        roomId: roomId,
        matrixUserId: matrixUserId,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
        message: message ?? this.message,
        connectedAt:
            clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
      );
}

final class CallController extends ChangeNotifier {
  CallController({
    required this.backend,
    required this.permissions,
    CallAlerts? alerts,
    CallSoundCues? soundCues,
    CallDiagnostics? diagnostics,
    this.ringTimeout = callRingTimeout,
    this.connectTimeout = callConnectTimeout,
  })  : alerts = alerts ?? CallAlerts(),
        soundCues = soundCues ?? const NotificationSystemCallSoundCues(),
        diagnostics = diagnostics ?? CallDiagnostics() {
    _events = backend.callEvents.listen(_handleEvent);
  }

  final CallBackend backend;
  final CallPermissionGateway permissions;
  final CallAlerts alerts;

  /// 接通/结束提示音（PRD §5）。
  final CallSoundCues soundCues;

  /// 关键路径耗时诊断（与 backend 共享同一实例/时间线）。
  final CallDiagnostics diagnostics;

  /// 主叫等待超时：到点未接通自动挂断并提示。
  final Duration ringTimeout;

  /// 被叫接听后的连接超时：到点 ICE 未接通 → failed（可重试）。
  final Duration connectTimeout;

  late final StreamSubscription<CallBackendEvent> _events;
  Timer? _ringTimeoutTimer;
  Timer? _connectTimeoutTimer;
  CallViewState state = const CallViewState(CallPhase.idle);
  bool _incomingRinging = false;

  Future<void> start({
    required String roomId,
    required String matrixUserId,
    required CallMediaType type,
  }) async {
    _set(CallViewState(
      CallPhase.requestingPermission,
      roomId: roomId,
      matrixUserId: matrixUserId,
      type: type,
    ));
    if (!await backend.isEncryptedDirectRoom(roomId, matrixUserId)) {
      _set(
          state.copyWith(phase: CallPhase.failed, message: '只能在已验证的加密双人会话中通话'));
      throw StateError('Call room is not an encrypted direct room');
    }
    if (!await permissions.request(video: type == CallMediaType.video)) {
      _set(state.copyWith(
          phase: CallPhase.permissionDenied, message: '需要麦克风和摄像头权限'));
      return;
    }
    try {
      await backend.start(roomId, matrixUserId, type);
      _incomingRinging = false; // 主叫：等待音。
      _set(state.copyWith(phase: CallPhase.ringing));
      _armRingTimeout();
    } catch (_) {
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

  /// P0（接听加固）：权限失败拒接；信令异常不再裸抛（此前无 try/catch，
  /// ICE 不通则永远停在响铃界面）——进入 failed 可重试；
  /// 接听后进入 connecting 并布防连接超时。
  Future<void> accept() async {
    final type = state.type ?? CallMediaType.audio;
    diagnostics.mark(CallDiagStage.answerTapped);
    _set(state.copyWith(phase: CallPhase.requestingPermission));
    if (!await permissions.request(video: type == CallMediaType.video)) {
      await _safeReject();
      _set(state.copyWith(
          phase: CallPhase.permissionDenied, message: '权限被拒绝，已拒接来电'));
      return;
    }
    try {
      await backend.accept();
      diagnostics.mark(CallDiagStage.answerSent);
      _incomingRinging = false; // 已接听：停止来电铃（等待音语义不适用）。
      _set(state.copyWith(phase: CallPhase.connecting));
      _armConnectTimeout();
    } catch (_) {
      _acceptFailed('接听失败，请重试');
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
    _connectTimeoutTimer = Timer(connectTimeout, () async {
      if (state.phase != CallPhase.connecting) return;
      await _safeHangup();
      _set(state.copyWith(phase: CallPhase.failed, message: '接通超时，请重试'));
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
    alerts.stop();
    _ringTimeoutTimer?.cancel();
    await _safeReject();
    _set(state.copyWith(phase: CallPhase.ended, message: '已拒接'));
  }

  Future<void> hangup() async {
    alerts.stop();
    _ringTimeoutTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    await _safeHangup();
    _set(state.copyWith(phase: CallPhase.ended, message: '通话已结束'));
  }

  Future<void> toggleMute() async {
    final muted = !state.muted;
    await backend.setMuted(muted);
    _set(state.copyWith(muted: muted));
  }

  Future<void> toggleSpeaker() async {
    final speaker = !state.speaker;
    await backend.setSpeaker(speaker);
    _set(state.copyWith(speaker: speaker));
  }

  Future<void> switchCamera() => backend.switchCamera();

  Future<void> _handleEvent(CallBackendEvent event) async {
    switch (event.kind) {
      case CallBackendEventKind.incoming:
        _incomingRinging = true;
        diagnostics.mark(CallDiagStage.incomingUiShown);
        _set(CallViewState(
          CallPhase.ringing,
          roomId: event.roomId,
          matrixUserId: event.matrixUserId,
          type: event.type,
        ));
      case CallBackendEventKind.connected:
        _incomingRinging = false;
        diagnostics.mark(CallDiagStage.iceConnected);
        // 接通即停铃；视频通话默认打开免提（微信语义），语音保持听筒。
        alerts.stop();
        _ringTimeoutTimer?.cancel();
        _connectTimeoutTimer?.cancel();
        final isVideo = state.type == CallMediaType.video;
        if (isVideo && !state.speaker) {
          try {
            await backend.setSpeaker(true);
          } catch (_) {
            // 免提切换失败不影响接通。
          }
        }
        _set(state.copyWith(
          phase: CallPhase.connected,
          speaker: isVideo ? true : null,
          connectedAt: DateTime.now(),
        ));
      case CallBackendEventKind.ended:
        _set(state.copyWith(phase: CallPhase.ended, message: '通话已结束'));
      case CallBackendEventKind.networkInterrupted:
        _set(state.copyWith(phase: CallPhase.ended, message: '网络中断，通话已结束'));
    }
  }

  void _set(CallViewState next) {
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
    _ringTimeoutTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    alerts.stop();
    _events.cancel();
    super.dispose();
  }
}
