import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show SyncStatus, SyncStatusUpdate;

import '../../core/performance_trace.dart';
import 'matrix_sync_recovery_controller.dart';

/// Only a real hidden/paused transition starts a resume sample. A transient
/// inactive state can occur for a system overlay while the app stays visible.
bool isPerformanceBackgroundTransition(AppLifecycleState state) =>
    state == AppLifecycleState.hidden || state == AppLifecycleState.paused;

/// Records only real post-background recovery signals. It never initiates a
/// probe, sync, route transition or database read.
final class AppResumePerformanceObserver {
  AppResumePerformanceObserver({
    required PerformanceTraceRecorder recorder,
    required ValueListenable<MatrixConnectionStatus> connectionStatus,
    required Stream<SyncStatusUpdate> syncStatus,
    required void Function(VoidCallback callback) afterFirstFrame,
    required bool Function() conversationOpen,
    required int Function() softKicks,
    required int Function() hardRestarts,
    int Function()? syncErrors,
    int Function()? reconnects,
    Duration? Function()? lastHealthySyncAge,
    this.timeout = PerformanceThresholds.remoteSyncObservationWindow,
  })  : _recorder = recorder,
        _connectionStatus = connectionStatus,
        _syncStatus = syncStatus,
        _afterFirstFrame = afterFirstFrame,
        _conversationOpen = conversationOpen,
        _softKicks = softKicks,
        _hardRestarts = hardRestarts,
        _syncErrors = syncErrors,
        _reconnects = reconnects,
        _lastHealthySyncAge = lastHealthySyncAge;

  final PerformanceTraceRecorder _recorder;
  final ValueListenable<MatrixConnectionStatus> _connectionStatus;
  final Stream<SyncStatusUpdate> _syncStatus;
  final void Function(VoidCallback callback) _afterFirstFrame;
  final bool Function() _conversationOpen;
  final int Function() _softKicks;
  final int Function() _hardRestarts;
  final int Function()? _syncErrors;
  final int Function()? _reconnects;
  final Duration? Function()? _lastHealthySyncAge;
  final Duration timeout;
  StreamSubscription<SyncStatusUpdate>? _syncSubscription;
  Timer? _deadline;
  PerformanceTrace? _trace;
  bool _backgroundObserved = false;
  bool _needsConversation = false;
  bool _firstFrameSeen = false;
  bool _connectedSeen = false;
  bool _syncSeen = false;
  bool _conversationSeen = false;
  bool _disposed = false;
  int _softStart = 0;
  int _hardStart = 0;
  int _syncErrorStart = 0;
  int _reconnectStart = 0;

  void onBackground() {
    if (_disposed) return;
    _backgroundObserved = true;
    if (_trace != null) _finish(PerformanceResult.cancelled);
  }

  void onForeground() {
    if (_disposed || !_backgroundObserved) return;
    _backgroundObserved = false;
    if (!_recorder.recordingEnabled) return;
    _softStart = _softKicks();
    _hardStart = _hardRestarts();
    _syncErrorStart = _syncErrors?.call() ?? 0;
    _reconnectStart = _reconnects?.call() ?? 0;
    _needsConversation = _conversationOpen();
    _firstFrameSeen = false;
    _connectedSeen = false;
    _syncSeen = false;
    _conversationSeen = false;
    final trace = _recorder.start(PerformanceOperationType.appResume);
    _trace = trace;
    _connectionStatus.addListener(_onConnection);
    _syncSubscription = _syncStatus.listen(_onSync);
    _onConnection();
    _afterFirstFrame(() {
      if (!identical(_trace, trace)) return;
      _firstFrameSeen = true;
      trace.mark(PerformanceStage.firstFrameRendered);
      _maybeFinish();
    });
    _deadline = Timer(timeout, () {
      if (identical(_trace, trace)) {
        _finish(PerformanceResult.waitingNetwork);
      }
    });
  }

  void onConversationReady() {
    final trace = _trace;
    if (trace == null || !_needsConversation) return;
    _conversationSeen = true;
    trace.mark(PerformanceStage.conversationReady);
    _maybeFinish();
  }

  void _onConnection() {
    final trace = _trace;
    if (trace == null) return;
    final status = _connectionStatus.value;
    if (status == MatrixConnectionStatus.connected) {
      _connectedSeen = true;
      trace.mark(PerformanceStage.matrixConnected);
      trace.setNetwork(matrixConnection: PerformanceMatrixState.connected);
      _maybeFinish();
    } else if (status == MatrixConnectionStatus.connecting) {
      trace.setNetwork(matrixConnection: PerformanceMatrixState.connecting);
    } else if (status != MatrixConnectionStatus.unknown) {
      trace.setNetwork(matrixConnection: PerformanceMatrixState.disconnected);
    }
  }

  void _onSync(SyncStatusUpdate update) {
    final trace = _trace;
    if (trace == null) return;
    if (update.status == SyncStatus.finished) {
      _syncSeen = true;
      trace.mark(PerformanceStage.syncFinished);
      _maybeFinish();
    } else if (update.status == SyncStatus.error) {
      trace.setNetwork(matrixConnection: PerformanceMatrixState.disconnected);
    }
  }

  void _maybeFinish() {
    if (_firstFrameSeen &&
        _connectedSeen &&
        _syncSeen &&
        (!_needsConversation || _conversationSeen)) {
      _finish(PerformanceResult.success);
    }
  }

  void _finish(PerformanceResult result) {
    final trace = _trace;
    if (trace == null) return;
    _trace = null;
    _deadline?.cancel();
    _deadline = null;
    _connectionStatus.removeListener(_onConnection);
    unawaited(_syncSubscription?.cancel());
    _syncSubscription = null;
    trace.softKickCount = (_softKicks() - _softStart).clamp(0, 1000);
    trace.hardRestartCount = (_hardRestarts() - _hardStart).clamp(0, 1000);
    if (_syncErrors case final errors?) {
      trace.syncErrorCount = (errors() - _syncErrorStart).clamp(0, 1000);
    }
    if (_reconnects case final reconnects?) {
      trace.reconnectCount = (reconnects() - _reconnectStart).clamp(0, 1000);
    }
    final healthyAge = _lastHealthySyncAge?.call();
    if (healthyAge != null) {
      trace.lastHealthySyncAgeMs =
          healthyAge.inMilliseconds.clamp(0, 3600000);
    }
    trace.finish(result: result);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _deadline?.cancel();
    _deadline = null;
    _connectionStatus.removeListener(_onConnection);
    unawaited(_syncSubscription?.cancel());
    _syncSubscription = null;
    _trace?.dispose();
    _trace = null;
  }
}
