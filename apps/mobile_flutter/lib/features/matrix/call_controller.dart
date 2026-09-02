import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_alerts.dart';

/// 主叫无人接听的自动取消时长（微信语义：约 60 秒后提示无应答）。
const callRingTimeout = Duration(seconds: 60);

/// 通话时长展示格式：mm:ss（超 1 小时 h:mm:ss）。
String formatCallDuration(Duration duration) {
  final total = duration.inSeconds.clamp(0, 24 * 3600);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:${two(minutes)}:${two(seconds)}' : '${two(minutes)}:${two(seconds)}';
}

enum CallMediaType { audio, video }

enum CallPhase {
  idle,
  requestingPermission,
  ringing,
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
        connectedAt: clearConnectedAt ? null : (connectedAt ?? this.connectedAt),
      );
}

final class CallController extends ChangeNotifier {
  CallController({
    required this.backend,
    required this.permissions,
    CallAlerts? alerts,
    this.ringTimeout = callRingTimeout,
  })  : alerts = alerts ?? CallAlerts() {
    _events = backend.callEvents.listen(_handleEvent);
  }

  final CallBackend backend;
  final CallPermissionGateway permissions;
  final CallAlerts alerts;

  /// 主叫等待超时：到点未接通自动挂断并提示。
  final Duration ringTimeout;

  late final StreamSubscription<CallBackendEvent> _events;
  Timer? _ringTimeoutTimer;
  CallViewState state = const CallViewState(CallPhase.idle);

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
      _set(state.copyWith(phase: CallPhase.ringing));
      _armRingTimeout();
    } catch (_) {
      alerts.stop();
      _set(state.copyWith(phase: CallPhase.failed, message: '呼叫失败，请重试'));
      rethrow;
    }
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

  Future<void> accept() async {
    final type = state.type ?? CallMediaType.audio;
    _set(state.copyWith(phase: CallPhase.requestingPermission));
    if (!await permissions.request(video: type == CallMediaType.video)) {
      await backend.reject();
      _set(state.copyWith(
          phase: CallPhase.permissionDenied, message: '权限被拒绝，已拒接来电'));
      return;
    }
    await backend.accept();
    _set(state.copyWith(phase: CallPhase.ringing));
  }

  Future<void> reject() async {
    alerts.stop();
    _ringTimeoutTimer?.cancel();
    await backend.reject();
    _set(state.copyWith(phase: CallPhase.ended, message: '已拒接'));
  }

  Future<void> hangup() async {
    alerts.stop();
    _ringTimeoutTimer?.cancel();
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
        _set(CallViewState(
          CallPhase.ringing,
          roomId: event.roomId,
          matrixUserId: event.matrixUserId,
          type: event.type,
        ));
        alerts.start();
      case CallBackendEventKind.connected:
        // 接通即停铃；视频通话默认打开免提（微信语义），语音保持听筒。
        alerts.stop();
        _ringTimeoutTimer?.cancel();
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
        _set(state.copyWith(
            phase: CallPhase.ended, message: '网络中断，通话已结束'));
    }
  }

  void _set(CallViewState next) {
    final previousPhase = state.phase;
    state = next;
    // 响铃阶段维持提醒；接通/结束/失败等其余状态一律停铃。
    if (next.phase == CallPhase.ringing) {
      alerts.start();
    } else if (previousPhase == CallPhase.ringing &&
        next.phase != CallPhase.ringing) {
      alerts.stop();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ringTimeoutTimer?.cancel();
    alerts.stop();
    _events.cancel();
    super.dispose();
  }
}
