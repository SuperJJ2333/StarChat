import 'dart:async';

import 'package:flutter/foundation.dart';

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
  });
  final CallPhase phase;
  final CallMediaType? type;
  final String? roomId;
  final String? matrixUserId;
  final bool muted;
  final bool speaker;
  final String? message;

  CallViewState copyWith({
    CallPhase? phase,
    bool? muted,
    bool? speaker,
    String? message,
  }) =>
      CallViewState(
        phase ?? this.phase,
        type: type,
        roomId: roomId,
        matrixUserId: matrixUserId,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
        message: message ?? this.message,
      );
}

final class CallController extends ChangeNotifier {
  CallController({required this.backend, required this.permissions}) {
    _events = backend.callEvents.listen(_handleEvent);
  }

  final CallBackend backend;
  final CallPermissionGateway permissions;
  late final StreamSubscription<CallBackendEvent> _events;
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
    } catch (_) {
      _set(state.copyWith(phase: CallPhase.failed, message: '呼叫失败，请重试'));
      rethrow;
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
    await backend.reject();
    _set(state.copyWith(phase: CallPhase.ended, message: '已拒接'));
  }

  Future<void> hangup() async {
    await backend.hangup();
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

  void _handleEvent(CallBackendEvent event) {
    switch (event.kind) {
      case CallBackendEventKind.incoming:
        _set(CallViewState(
          CallPhase.ringing,
          roomId: event.roomId,
          matrixUserId: event.matrixUserId,
          type: event.type,
        ));
      case CallBackendEventKind.connected:
        _set(state.copyWith(phase: CallPhase.connected));
      case CallBackendEventKind.ended:
        _set(state.copyWith(phase: CallPhase.ended, message: '通话已结束'));
      case CallBackendEventKind.networkInterrupted:
        _set(state.copyWith(phase: CallPhase.ended, message: '网络中断，通话已结束'));
    }
  }

  void _set(CallViewState next) {
    state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _events.cancel();
    super.dispose();
  }
}
