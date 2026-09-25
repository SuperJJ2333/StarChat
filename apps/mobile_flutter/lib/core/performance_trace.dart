import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:uuid/uuid.dart';

import 'chat_diagnostics.dart';
import 'performance_metrics.dart';
import 'performance_trace_model.dart';

export 'performance_trace_model.dart';

final class _PendingFrameRecord {
  _PendingFrameRecord(
    this.record,
    this.startUs,
    this.endUs,
    this.sessionGeneration,
    this.frames,
  );

  final PerformanceRecord record;
  final int startUs;
  final int endUs;
  final int? sessionGeneration;
  final _MutableFrameCounts frames;
  Timer? deadline;
}

final class _MutableFrameCounts {
  int total = 0;
  int slow = 0;
  int slowBuild = 0;
  int slowRaster = 0;

  void add(FrameTiming timing, int budgetUs) {
    final build = timing.buildDuration.inMicroseconds > budgetUs;
    final raster = timing.rasterDuration.inMicroseconds > budgetUs;
    total++;
    if (build) slowBuild++;
    if (raster) slowRaster++;
    if (build || raster) slow++;
  }

  PerformanceFrameCounts snapshot() => PerformanceFrameCounts(
        total: total,
        slow: slow,
        slowBuild: slowBuild,
        slowRaster: slowRaster,
      );
}

/// Coordinates active operations while the existing PerformanceMetrics and
/// ChatDiagnostics remain the bounded stores. Tests inject a monotonic clock.
final class PerformanceTraceRecorder {
  PerformanceTraceRecorder({
    PerformanceMetrics? metrics,
    int Function()? clockUs,
    int Function()? frameClockUs,
    PerformanceFrameCounts Function()? frameCounts,
    int Function()? sessionGeneration,
    bool Function()? enabled,
    this.timestampedFrameAttribution = false,
    this.frameAttributionSupported = true,
    this.activeCapacity = PerformanceThresholds.maxActiveTraces,
    this.onRecord,
  })  : metrics = metrics ?? PerformanceMetrics.instance,
        _clockUs = clockUs ?? _defaultClockUs,
        _frameClockUs = frameClockUs ?? _defaultFrameClockUs,
        _frameCounts = frameCounts ??
            (() => (metrics ?? PerformanceMetrics.instance).frameCounts),
        _sessionGeneration = sessionGeneration,
        _enabled = enabled ??
            (() => (metrics ?? PerformanceMetrics.instance).enabled) {
    if (activeCapacity <= 0) {
      throw ArgumentError.value(activeCapacity, 'activeCapacity');
    }
    if (timestampedFrameAttribution) {
      if (!this.metrics.enabled) {
        throw ArgumentError('Timestamped frames require enabled metrics');
      }
    }
  }

  static final Stopwatch _clock = Stopwatch()..start();
  static int _defaultClockUs() => _clock.elapsedMicroseconds;
  static int _defaultFrameClockUs() => developer.Timeline.now;
  static final instance = PerformanceTraceRecorder(
    timestampedFrameAttribution: PerformanceMetrics.instance.enabled,
    frameAttributionSupported: PerformanceMetrics.instance.enabled,
    frameCounts: () => PerformanceMetrics.instance.enabled
        ? PerformanceMetrics.instance.frameCounts
        : ChatDiagnostics.instance.cumulativeFrameCounts,
    sessionGeneration: () => ChatDiagnostics.instance.sessionGeneration,
    enabled: () =>
        PerformanceMetrics.instance.enabled ||
        ChatDiagnostics.instance.isActive,
    onRecord: ChatDiagnostics.instance.recordPerformance,
  );

  final PerformanceMetrics metrics;
  final int Function() _clockUs;
  final int Function() _frameClockUs;
  final PerformanceFrameCounts Function() _frameCounts;
  final int Function()? _sessionGeneration;
  final bool Function() _enabled;
  final int activeCapacity;
  final bool timestampedFrameAttribution;
  final bool frameAttributionSupported;
  final void Function(PerformanceRecord record)? onRecord;
  final Set<PerformanceTrace> _active = <PerformanceTrace>{};
  final _pendingFrames = ListQueue<_PendingFrameRecord>();
  bool _frameListenerRegistered = false;
  PerformanceLifecycle lifecycle = PerformanceLifecycle.unknown;
  int get activeCount => _active.length;
  int get pendingFrameAttributionCount => _pendingFrames.length;
  bool get recordingEnabled => _enabled() && _active.length < activeCapacity;

  PerformanceTrace start(
    PerformanceOperationType operation, {
    PerformanceTrace? parentOperation,
    PerformanceOpeningSource? openingSource,
    PerformanceAppNetworkState appNetworkState =
        PerformanceAppNetworkState.unknown,
    PerformanceMatrixState matrixState = PerformanceMatrixState.unknown,
    bool? transportAvailable,
    bool? serviceReachable,
    PerformanceEndpointCategory? endpointCategory,
    PerformanceHttpMethod? httpMethod,
  }) {
    final canRecord = recordingEnabled;
    if (canRecord && timestampedFrameAttribution && !_frameListenerRegistered) {
      _frameListenerRegistered =
          metrics.addFrameTimingListener(_onFrameTimings);
    }
    final generation = _sessionGeneration?.call();
    final inheritId = canRecord &&
        parentOperation != null &&
        identical(parentOperation._recorder, this) &&
        parentOperation.isRecording &&
        (parentOperation._sessionGeneration == null ||
            parentOperation._sessionGeneration == generation);
    final trace = PerformanceTrace._(
      recorder: this,
      operation: operation,
      operationId: canRecord
          ? inheritId
              ? parentOperation.operationId
              : const Uuid().v4()
          : '00000000-0000-4000-8000-000000000000',
      startedUs: _clockUs(),
      frameStartedUs:
          canRecord && timestampedFrameAttribution && _frameListenerRegistered
              ? _frameClockUs()
              : null,
      frameStart: _frameCounts(),
      sessionGeneration: generation,
      recording: canRecord,
      lifecycle: lifecycle,
      openingSource: openingSource,
      appNetworkState: appNetworkState,
      matrixState: matrixState,
      transportAvailable: transportAvailable,
      serviceReachable: serviceReachable,
      endpointCategory: endpointCategory,
      httpMethod: httpMethod,
    );
    if (canRecord) _active.add(trace);
    return trace;
  }

  void clear() {
    for (final trace in _active.toList(growable: false)) {
      trace.dispose();
    }
    _active.clear();
    for (final pending in _pendingFrames) {
      pending.deadline?.cancel();
    }
    _pendingFrames.clear();
    _releaseFrameListenerIfIdle();
  }

  void _releaseFrameListenerIfIdle() {
    if (_frameListenerRegistered && _active.isEmpty && _pendingFrames.isEmpty) {
      metrics.removeFrameTimingListener(_onFrameTimings);
      _frameListenerRegistered = false;
    }
  }

  void _emit(PerformanceRecord record, int? generation) {
    if (generation != null && generation != _sessionGeneration?.call()) return;
    metrics.recordTrace(record);
    onRecord?.call(record);
  }

  void _finalizeFrameRecord(
      _PendingFrameRecord pending, PerformanceFrameCounts? frames) {
    if (!_pendingFrames.remove(pending)) return;
    pending.deadline?.cancel();
    _emit(
      frames == null
          ? pending.record
          : pending.record.withFrameAttribution(frames, complete: true),
      pending.sessionGeneration,
    );
    _releaseFrameListenerIfIdle();
  }

  /// Incremental attribution keeps a long operation's counts without scanning
  /// a global sample ring. Each batch visits at most the bounded active and
  /// pending traces, and only real build/raster timestamps decide membership.
  void _onFrameTimings(
      List<FrameTiming> timings, int budgetUs, bool clockValid) {
    if (!clockValid) {
      for (final trace in _active) {
        trace._frameClockValid = false;
      }
      for (final pending in _pendingFrames.toList(growable: false)) {
        _finalizeFrameRecord(pending, null);
      }
      return;
    }
    if (timings.isEmpty) return;
    for (final timing in timings) {
      final buildStartUs =
          timing.timestampInMicroseconds(FramePhase.buildStart);
      for (final trace in _active) {
        final startUs = trace._frameStartedUs;
        if (trace._frameClockValid &&
            startUs != null &&
            buildStartUs >= startUs) {
          trace._timedFrames!.add(timing, budgetUs);
        }
      }
      for (final pending in _pendingFrames) {
        if (buildStartUs >= pending.startUs && buildStartUs <= pending.endUs) {
          pending.frames.add(timing, budgetUs);
        }
      }
    }
    final rasterFinishUs =
        timings.last.timestampInMicroseconds(FramePhase.rasterFinish);
    for (final pending in _pendingFrames.toList(growable: false)) {
      if (rasterFinishUs >= pending.endUs) {
        _finalizeFrameRecord(pending, pending.frames.snapshot());
      }
    }
  }

  void _queueFrameRecord(PerformanceRecord record, int startUs, int endUs,
      int? sessionGeneration, _MutableFrameCounts frames) {
    if (_pendingFrames.length == activeCapacity) {
      _finalizeFrameRecord(_pendingFrames.first, null);
    }
    final pending =
        _PendingFrameRecord(record, startUs, endUs, sessionGeneration, frames);
    _pendingFrames.addLast(pending);
    pending.deadline =
        Timer(PerformanceThresholds.frameTimingAttributionTimeout, () {
      _finalizeFrameRecord(pending, null);
    });
  }
}

/// One operation ID is created at the user action and passed across existing
/// navigation, outbox and Matrix callbacks. Marks only read a monotonic clock.
final class PerformanceTrace {
  static final Object _operationZoneKey = Object();

  /// Only an explicitly scoped, still active operation can parent a child
  /// request. Dart zones isolate concurrent async branches without globals.
  static PerformanceTrace? get currentOperation =>
      Zone.current[_operationZoneKey] as PerformanceTrace?;

  Future<T> runChildOperations<T>(Future<T> Function() operation) => isRecording
      ? runZoned(operation, zoneValues: {_operationZoneKey: this})
      : operation();

  /// Starts a separate user operation in this trace's recorder. Page refreshes
  /// use this after the entry trace has finished, including injected recorders.
  PerformanceTrace startSiblingOperation(PerformanceOperationType operation) =>
      _recorder.start(operation);

  PerformanceTrace._({
    required PerformanceTraceRecorder recorder,
    required this.operation,
    required this.operationId,
    required int startedUs,
    required int? frameStartedUs,
    required PerformanceFrameCounts frameStart,
    int? sessionGeneration,
    required bool recording,
    required this.lifecycle,
    this.openingSource,
    this.appNetworkState = PerformanceAppNetworkState.unknown,
    this.matrixState = PerformanceMatrixState.unknown,
    this.transportAvailable,
    this.serviceReachable,
    this.endpointCategory,
    this.httpMethod,
  })  : _recorder = recorder,
        _startedUs = startedUs,
        _frameStartedUs = frameStartedUs,
        _timedFrames = frameStartedUs == null ? null : _MutableFrameCounts(),
        _frameStart = frameStart,
        _sessionGeneration = sessionGeneration,
        _recording = recording;

  static PerformanceTrace start({
    required PerformanceOperationType operation,
    PerformanceOpeningSource? openingSource,
    PerformanceAppNetworkState appNetworkState =
        PerformanceAppNetworkState.unknown,
    PerformanceMatrixState matrixState = PerformanceMatrixState.unknown,
    bool? transportAvailable,
    bool? serviceReachable,
    PerformanceEndpointCategory? endpointCategory,
    PerformanceHttpMethod? httpMethod,
  }) =>
      PerformanceTraceRecorder.instance.start(
        operation,
        openingSource: openingSource,
        appNetworkState: appNetworkState,
        matrixState: matrixState,
        transportAvailable: transportAvailable,
        serviceReachable: serviceReachable,
        endpointCategory: endpointCategory,
        httpMethod: httpMethod,
      );

  final PerformanceTraceRecorder _recorder;
  final PerformanceOperationType operation;
  final String operationId;
  final int _startedUs;
  final int? _frameStartedUs;
  final PerformanceFrameCounts _frameStart;
  final _MutableFrameCounts? _timedFrames;
  bool _frameClockValid = true;
  final int? _sessionGeneration;
  final PerformanceLifecycle lifecycle;
  PerformanceOpeningSource? openingSource;
  PerformanceAppNetworkState appNetworkState;
  PerformanceMatrixState matrixState;
  bool? transportAvailable;
  bool? serviceReachable;
  PerformanceEndpointCategory? endpointCategory;
  PerformanceHttpMethod? httpMethod;
  PerformanceNetworkError? networkError;
  PerformanceCacheSource? cacheSource;
  PerformanceMediaType? mediaType;
  PerformanceSizeBucket? sizeBucket;
  PerformanceDatabaseOperation? databaseOperation;
  PerformanceRowCountBucket? rowCountBucket;
  PerformanceRowCountBucket? resultCountBucket;
  int? schedulerQueue;
  int? schedulerActive;
  int? schedulerVideoActive;
  PerformanceMediaPriority? mediaPriority;
  int? statusCode;
  int retryCount = 0;
  int softKickCount = 0;
  int hardRestartCount = 0;
  int? syncErrorCount;
  int? reconnectCount;
  int? lastHealthySyncAgeMs;
  double? _rttMs;
  double? _jitterMs;
  int? _packetsLost;
  int? _packetsReceived;
  bool? _usesTurn;
  PerformanceRelayProtocol? _relayProtocol;
  PerformanceRelayProtocol? _candidateProtocol;

  final _stagesUs = <PerformanceStage, int>{};
  final _videoTranscodeAttempts = <PerformanceVideoTranscodeAttempt>[];
  bool _recording;
  bool _disposed = false;
  PerformanceRecord? _finished;

  bool get isRecording => _recording && !_disposed && _finished == null;
  bool get isFinished => _disposed || _finished != null;

  void mark(PerformanceStage stage) {
    if (!isRecording ||
        _stagesUs.containsKey(stage) ||
        _stagesUs.length >= PerformanceThresholds.maxStagesPerTrace) {
      return;
    }
    final elapsed = _recorder._clockUs() - _startedUs;
    _stagesUs[stage] = elapsed < 0 ? 0 : elapsed;
  }

  /// Records at most one observation per supported encoder profile. The API
  /// accepts no path, exception message, metadata map or other free text.
  void recordVideoTranscodeAttempt({
    required PerformanceVideoTranscodeProfile profile,
    required PerformanceVideoTranscodeOutcome outcome,
    required Duration duration,
  }) {
    if (!isRecording ||
        operation != PerformanceOperationType.videoPrepare ||
        duration.isNegative ||
        _videoTranscodeAttempts.length >= 2 ||
        _videoTranscodeAttempts.any((attempt) => attempt.profile == profile)) {
      return;
    }
    _videoTranscodeAttempts.add(PerformanceVideoTranscodeAttempt(
      profile: profile,
      outcome: outcome,
      durationMs: duration.inMilliseconds.clamp(0, 3600000),
    ));
  }

  void setOpeningSource(PerformanceOpeningSource source) {
    if (isRecording) openingSource = source;
  }

  void setNetwork({
    PerformanceAppNetworkState? appState,
    PerformanceMatrixState? matrixConnection,
    bool? transport,
    bool? service,
    PerformanceNetworkError? error,
  }) {
    if (!isRecording) return;
    if (appState != null) appNetworkState = appState;
    if (matrixConnection != null) matrixState = matrixConnection;
    if (transport != null) transportAvailable = transport;
    if (service != null) serviceReachable = service;
    if (error != null) networkError = error;
  }

  void setMedia({
    PerformanceCacheSource? source,
    PerformanceMediaType? type,
    PerformanceSizeBucket? size,
    int? queued,
    int? active,
    int? videoActive,
    PerformanceMediaPriority? priority,
  }) {
    if (!isRecording) return;
    if (source != null) cacheSource = source;
    if (type != null) mediaType = type;
    if (size != null) sizeBucket = size;
    if (queued != null) schedulerQueue = queued.clamp(0, 1000);
    if (active != null) schedulerActive = active.clamp(0, 1000);
    if (videoActive != null) schedulerVideoActive = videoActive.clamp(0, 1000);
    if (priority != null) mediaPriority = priority;
  }

  /// Retains a coarse count only. SQL and result data never enter the trace.
  void setDatabase({
    required PerformanceDatabaseOperation operation,
    required int rowCount,
  }) {
    if (!isRecording || rowCount < 0) return;
    databaseOperation = operation;
    rowCountBucket = _countBucket(rowCount);
  }

  void setSearchResultCount(int resultCount) {
    if (!isRecording || resultCount < 0) return;
    resultCountBucket = _countBucket(resultCount);
  }

  static PerformanceRowCountBucket _countBucket(int count) => switch (count) {
        0 => PerformanceRowCountBucket.zero,
        <= 20 => PerformanceRowCountBucket.oneToTwenty,
        <= 100 => PerformanceRowCountBucket.twentyOneToHundred,
        <= 500 => PerformanceRowCountBucket.hundredOneToFiveHundred,
        _ => PerformanceRowCountBucket.overFiveHundred,
      };

  void setCallQuality({
    double? rttMs,
    double? jitterMs,
    int? packetsLost,
    int? packetsReceived,
    bool? usesTurn,
    PerformanceRelayProtocol? relayProtocol,
    PerformanceRelayProtocol? candidateProtocol,
  }) {
    if (!isRecording) return;
    if (rttMs != null && rttMs.isFinite && rttMs >= 0) _rttMs = rttMs;
    if (jitterMs != null && jitterMs.isFinite && jitterMs >= 0) {
      _jitterMs = jitterMs;
    }
    if (packetsLost != null && packetsLost >= 0) _packetsLost = packetsLost;
    if (packetsReceived != null && packetsReceived >= 0) {
      _packetsReceived = packetsReceived;
    }
    if (usesTurn != null) _usesTurn = usesTurn;
    if (relayProtocol != null) _relayProtocol = relayProtocol;
    if (candidateProtocol != null) _candidateProtocol = candidateProtocol;
  }

  PerformanceRecord finish({
    PerformanceResult result = PerformanceResult.success,
    int? statusCode,
    int retryCount = 0,
    PerformanceNetworkError? networkError,
  }) {
    final completed = _finished;
    if (completed != null) return completed;
    final elapsed = _recorder._clockUs() - _startedUs;
    final frameEndedUs =
        _frameStartedUs == null ? null : _recorder._frameClockUs();
    final canEmit = _recording &&
        !_disposed &&
        (_sessionGeneration == null ||
            _sessionGeneration == _recorder._sessionGeneration?.call());
    final record = PerformanceRecord(
      operationId: operationId,
      operation: operation,
      totalUs: elapsed < 0 ? 0 : elapsed,
      stagesUs: _stagesUs,
      result: result,
      lifecycle: lifecycle,
      frames: _recorder.frameAttributionSupported &&
              !_recorder.timestampedFrameAttribution
          ? _recorder._frameCounts().difference(_frameStart)
          : const PerformanceFrameCounts(),
      frameAttributionComplete: _recorder.frameAttributionSupported &&
          !_recorder.timestampedFrameAttribution,
      openingSource: openingSource,
      appNetworkState: appNetworkState,
      matrixState: matrixState,
      transportAvailable: transportAvailable,
      serviceReachable: serviceReachable,
      networkError: networkError ?? this.networkError,
      endpointCategory: endpointCategory,
      httpMethod: httpMethod,
      statusCode: statusCode ?? this.statusCode,
      retryCount: retryCount > 0 ? retryCount : this.retryCount,
      softKickCount: softKickCount,
      hardRestartCount: hardRestartCount,
      syncErrorCount: syncErrorCount,
      reconnectCount: reconnectCount,
      lastHealthySyncAgeMs: lastHealthySyncAgeMs,
      cacheSource: cacheSource,
      mediaType: mediaType,
      sizeBucket: sizeBucket,
      databaseOperation: databaseOperation,
      rowCountBucket: rowCountBucket,
      resultCountBucket: resultCountBucket,
      schedulerQueue: schedulerQueue,
      schedulerActive: schedulerActive,
      schedulerVideoActive: schedulerVideoActive,
      mediaPriority: mediaPriority,
      rttMs: _rttMs,
      jitterMs: _jitterMs,
      packetsLost: _packetsLost,
      packetsReceived: _packetsReceived,
      usesTurn: _usesTurn,
      relayProtocol: _relayProtocol,
      candidateProtocol: _candidateProtocol,
      videoTranscodeAttempts: _videoTranscodeAttempts,
    );
    _finished = record;
    _recorder._active.remove(this);
    if (canEmit) {
      if (frameEndedUs != null &&
          _frameStartedUs != null &&
          _frameClockValid &&
          frameEndedUs >= _frameStartedUs) {
        _recorder._queueFrameRecord(record, _frameStartedUs, frameEndedUs,
            _sessionGeneration, _timedFrames!);
      } else {
        _recorder._emit(record, _sessionGeneration);
      }
    }
    _recording = false;
    _recorder._releaseFrameListenerIfIdle();
    return record;
  }

  void dispose() {
    if (_disposed || _finished != null) return;
    _disposed = true;
    _recording = false;
    _recorder._active.remove(this);
    _stagesUs.clear();
    _videoTranscodeAttempts.clear();
    _recorder._releaseFrameListenerIfIdle();
  }
}
