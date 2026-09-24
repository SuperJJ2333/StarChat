import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';

import 'performance_trace_model.dart';

enum ChatDiagnosticStage {
  sendAdmission,
  matrixSend,
  historyLoad,
  historySearch,
  dateMonth,
  dateLocate,
  scrollAnchor,
  framework,
  refreshPendingWriteFailed,
  refreshRequestUncertain,
  refreshResultWriteFailed,
  refreshRetryRecovered,
  refreshTerminalInvalidated,
  refreshResultSuperseded;

  String get wireName => switch (this) {
        refreshPendingWriteFailed => 'pending_write_failed',
        refreshRequestUncertain => 'request_uncertain',
        refreshResultWriteFailed => 'result_write_failed',
        refreshRetryRecovered => 'retry_recovered',
        refreshTerminalInvalidated => 'terminal_invalidated',
        refreshResultSuperseded => 'result_superseded',
        _ => name,
      };
}

enum ChatDiagnosticError {
  slow,
  network,
  timeout,
  rejected,
  cancelled,
  incomplete,
  unknown,
  recovered,
}

enum ChatDiagnosticPlatform { android, ios, other }

enum ChatDiagnosticLifecycle { foreground, background, unknown }

typedef _EventKey = (
  ChatDiagnosticStage,
  ChatDiagnosticError,
  int?,
  int?,
  ChatDiagnosticLifecycle?
);

/// The transport must honor abort by closing its independent HTTP connection.
/// Its status is intentionally opaque to auth/session-refresh mechanisms.
typedef ChatDiagnosticUploader = Future<int> Function(
    ChatDiagnosticBatch batch, Future<void> abort);

final class ChatDiagnosticBatch {
  ChatDiagnosticBatch._(this.version, this.platform, List<_Event> events,
      this._frames, List<PerformanceRecord> operations)
      : _events = List.unmodifiable(events.map((e) => e.copy())),
        _operations = List.unmodifiable(operations);
  final String version;
  final ChatDiagnosticPlatform platform;
  final List<_Event> _events;
  final _FrameCounts? _frames;
  final List<PerformanceRecord> _operations;
  Map<String, Object?> toJson() => {
        'version': version,
        'platform': platform.name,
        'events': [for (final event in _events) event.toJson()],
        if (_frames != null) 'frames': _frames!.toJson(),
        if (_operations.isNotEmpty)
          'operations': [
            for (final operation in _operations) operation.toJson()
          ],
      };
}

final class _FrameCounts {
  int total = 0, slow = 0, build = 0, raster = 0;
  _FrameCounts copy() => _FrameCounts()
    ..total = total
    ..slow = slow
    ..build = build
    ..raster = raster;
  void subtract(_FrameCounts sent) {
    total -= sent.total;
    slow -= sent.slow;
    build -= sent.build;
    raster -= sent.raster;
  }

  Map<String, int> toJson() => {
        'frame_count': total,
        'slow_frame_count': slow,
        'slow_build_count': build,
        'slow_raster_count': raster,
      };
}

final class _Event {
  _Event(this.stage, this.error, this.status, this.elapsedMs, this.count,
      {String? operationId, this.retryCount, this.lifecycle})
      : operationId = operationId ?? const Uuid().v4();
  final ChatDiagnosticStage stage;
  final ChatDiagnosticError error;
  final int? status;
  final String operationId;
  final int? retryCount;
  final ChatDiagnosticLifecycle? lifecycle;
  int elapsedMs;
  int count;
  _EventKey get key => (stage, error, status, retryCount, lifecycle);
  _Event copy() => _Event(stage, error, status, elapsedMs, count,
      operationId: operationId, retryCount: retryCount, lifecycle: lifecycle);
  Map<String, Object?> toJson() => {
        'operation_id': operationId,
        'stage': stage.wireName,
        'error': error.name,
        'elapsed_ms': elapsedMs,
        'count': count,
        'status': status,
        if (retryCount != null) 'retry_count': retryCount,
        if (lifecycle != null) 'lifecycle': lifecycle!.name,
      };
}

/// In-memory only, closed metadata. Callers cannot submit text, IDs or stacks.
/// Recording is bounded O(1), never awaits, and never writes on the UI path.
final class ChatDiagnostics {
  static const _serverBodyLimitBytes = 16 * 1024;
  static const defaultMaxUploadBytes = 15 * 1024;

  ChatDiagnostics({
    DateTime Function()? now,
    this.normalSamplePercent = PerformanceThresholds.normalSamplePercent,
    this.maxUploadBytes = defaultMaxUploadBytes,
  }) : _now = now ?? DateTime.now {
    if (normalSamplePercent < 0 || normalSamplePercent > 100) {
      throw ArgumentError.value(normalSamplePercent, 'normalSamplePercent');
    }
    if (maxUploadBytes < 256 || maxUploadBytes > _serverBodyLimitBytes) {
      throw ArgumentError.value(maxUploadBytes, 'maxUploadBytes');
    }
  }
  static ChatDiagnostics instance = ChatDiagnostics();
  final DateTime Function() _now;
  final int normalSamplePercent;
  final int maxUploadBytes;
  final _pending = <_EventKey, _Event>{};
  final _pendingOperations = ListQueue<PerformanceRecord>();
  _FrameCounts _frames = _FrameCounts();
  _FrameCounts _cumulativeFrames = _FrameCounts();
  bool _framesSupported = true;
  bool _operationsSupported = true;
  ChatDiagnosticUploader? _upload;
  String _version = '';
  ChatDiagnosticPlatform _platform = ChatDiagnosticPlatform.other;
  Timer? _timer;
  Completer<void>? _abort;
  bool _inFlight = false;
  int _epoch = 0;
  int _failures = 0;
  DateTime? _nextAllowed;
  int get pendingCount => _pending.length + _pendingOperations.length;
  bool get isActive => _upload != null;
  PerformanceFrameCounts get cumulativeFrameCounts => PerformanceFrameCounts(
        total: _cumulativeFrames.total,
        slow: _cumulativeFrames.slow,
        slowBuild: _cumulativeFrames.build,
        slowRaster: _cumulativeFrames.raster,
      );

  /// Capture before an async operation; discard its diagnostic after logout.
  int get sessionGeneration => _epoch;

  void startSession(
      {required String version,
      required ChatDiagnosticPlatform platform,
      required ChatDiagnosticUploader upload}) {
    stopSession();
    if (!RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$').hasMatch(version)) {
      return;
    }
    _version = version;
    _platform = platform;
    _upload = upload;
    _nextAllowed = _now().add(const Duration(minutes: 1));
    _timer =
        Timer.periodic(const Duration(minutes: 1), (_) => unawaited(flush()));
  }

  void stopSession() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _upload = null;
    _pending.clear();
    _pendingOperations.clear();
    _frames = _FrameCounts();
    _cumulativeFrames = _FrameCounts();
    _framesSupported = true;
    _operationsSupported = true;
    _failures = 0;
    _nextAllowed = null;
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    // Do not release _inFlight here: the old transport must actually finish.
  }

  void record(
      {required ChatDiagnosticStage stage,
      required ChatDiagnosticError error,
      Duration elapsed = Duration.zero,
      int count = 1,
      int? status,
      int? retryCount,
      ChatDiagnosticLifecycle? lifecycle}) {
    if (_upload == null ||
        (error == ChatDiagnosticError.slow && elapsed.inMilliseconds < 250)) {
      return;
    }
    final safeStatus =
        status != null && status >= 100 && status <= 599 ? status : null;
    final safeRetryCount = retryCount?.clamp(0, 20);
    final key = (stage, error, safeStatus, safeRetryCount, lifecycle);
    final existing = _pending[key];
    final ms = elapsed.inMilliseconds.clamp(0, 3600000);
    final safeCount = count.clamp(1, 1000000);
    if (existing != null) {
      existing.count = (existing.count + safeCount).clamp(1, 1000000);
      existing.elapsedMs = math.max(existing.elapsedMs, ms);
      return;
    }
    if (pendingCount >= 100) return;
    _pending[key] = _Event(stage, error, safeStatus, ms, safeCount,
        retryCount: safeRetryCount, lifecycle: lifecycle);
  }

  /// Foreground frames only (enforced by the scope). A slow frame exceeds
  /// either pipeline stage's display budget; totalSpan is not a drop count.
  void recordFrame(
      {required int buildUs, required int rasterUs, required int budgetUs}) {
    if (_upload == null ||
        !_framesSupported ||
        _frames.total >= 1000000 ||
        budgetUs <= 0 ||
        buildUs < 0 ||
        rasterUs < 0) {
      return;
    }
    final slowBuild = buildUs > budgetUs;
    final slowRaster = rasterUs > budgetUs;
    _frames.total++;
    if (slowBuild) _frames.build++;
    if (slowRaster) _frames.raster++;
    if (slowBuild || slowRaster) _frames.slow++;
    _cumulativeFrames.total++;
    if (slowBuild) _cumulativeFrames.build++;
    if (slowRaster) _cumulativeFrames.raster++;
    if (slowBuild || slowRaster) _cumulativeFrames.slow++;
  }

  /// Receives immutable typed records from PerformanceTrace. Normal operations
  /// are sampled; slow outcomes and errors always enter this bounded queue.
  void recordPerformance(PerformanceRecord record) {
    if (_upload == null || !_operationsSupported) {
      return;
    }
    final mustKeep = _mustKeepPerformance(record);
    if (!mustKeep) {
      var hash = 0;
      for (final code in record.operationId.codeUnits) {
        hash = ((hash * 31) + code) & 0x7fffffff;
      }
      if (hash % 100 >= normalSamplePercent) return;
    }
    if (pendingCount >= 100) {
      if (!mustKeep) return;
      // Keep the newest slow/error evidence without growing the queue. Both
      // collections preserve insertion order; removal is constant time.
      if (_pendingOperations.length > 20) {
        // Flush reads the oldest records. Evict the tail so a concurrent
        // in-flight batch keeps its identity and cannot be sent twice.
        _pendingOperations.removeLast();
      } else if (_pending.isNotEmpty) {
        _pending.remove(_pending.keys.first);
      } else if (_pendingOperations.isNotEmpty) {
        _pendingOperations.removeLast();
      }
    }
    _pendingOperations.addLast(record);
  }

  bool _mustKeepPerformance(PerformanceRecord record) {
    if (record.result != PerformanceResult.success) return true;
    if (record.operation == PerformanceOperationType.conversationOpen) {
      final firstFrame = record.betweenMs(PerformanceStage.routePushStarted,
          PerformanceStage.firstFrameRendered);
      final localReady = record.betweenMs(
          PerformanceStage.userAction, PerformanceStage.localTimelineReady);
      final syncWait = record.conversationSyncWaitMs;
      final responseWait = record.betweenMs(
          PerformanceStage.syncResponseWaitStarted,
          PerformanceStage.syncResponseReceived);
      final processing = record.betweenMs(
          PerformanceStage.syncResponseReceived,
          PerformanceStage.syncProcessingDone);
      return (firstFrame != null &&
              firstFrame >= PerformanceThresholds.conversationFirstFrameMs) ||
          (localReady != null &&
              localReady >= PerformanceThresholds.conversationLocalReadyMs) ||
          (syncWait != null &&
              syncWait >= PerformanceThresholds.syncWaitMs) ||
          (responseWait != null &&
              responseWait >= PerformanceThresholds.syncWaitMs) ||
          (processing != null &&
              processing >= PerformanceThresholds.syncProcessingMs);
    }
    if (record.operation == PerformanceOperationType.matrixSync) {
      // A long /sync response wait is normal long-poll behavior. Retain a
      // successful cycle only when measured local processing/cleanup is slow.
      final processing = record.betweenMs(
          PerformanceStage.syncResponseReceived,
          PerformanceStage.syncProcessingDone);
      final cleanup = record.betweenMs(
          PerformanceStage.syncProcessingDone,
          PerformanceStage.syncCleanupDone);
      return (processing != null &&
              processing >= PerformanceThresholds.syncProcessingMs) ||
          (cleanup != null &&
              cleanup >= PerformanceThresholds.syncProcessingMs);
    }
    if (record.operation == PerformanceOperationType.callActive) {
      final loss = record.packetLossPercent;
      return (record.rttMs != null &&
              record.rttMs! >= PerformanceThresholds.callRttMs) ||
          (record.jitterMs != null &&
              record.jitterMs! >= PerformanceThresholds.callJitterMs) ||
          (loss != null &&
              loss >= PerformanceThresholds.callPacketLossPercent);
    }
    final threshold = switch (record.operation) {
      PerformanceOperationType.apiRequest =>
        PerformanceThresholds.businessApiMs,
      PerformanceOperationType.callSetup => PerformanceThresholds.callSetupMs,
      PerformanceOperationType.mediaLoad =>
        PerformanceThresholds.mediaFirstVisibleMs,
      _ => PerformanceThresholds.conversationLocalReadyMs,
    };
    return record.totalMs >= threshold;
  }

  /// Also bounded when explicitly requested: never bypasses cadence/backoff.
  Future<void> flush() async {
    final upload = _upload;
    final now = _now();
    if (upload == null ||
        (_pending.isEmpty &&
            _pendingOperations.isEmpty &&
            _frames.total == 0) ||
        _inFlight ||
        (_nextAllowed != null && now.isBefore(_nextAllowed!))) {
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final events = <_Event>[];
    final operations = <PerformanceRecord>[];
    _FrameCounts? frames = _frames.total > 0 ? _frames.copy() : null;

    // Encoding happens only on this low-frequency flush path. Count actual
    // UTF-8 body bytes, including JSON framing, below the server's 16 KiB cap.
    bool fits() =>
        utf8
            .encode(jsonEncode(ChatDiagnosticBatch._(
                    _version, _platform, events, frames, operations)
                .toJson()))
            .length <=
        maxUploadBytes;

    var batchFull = false;
    for (final event in _pending.values.take(20).toList(growable: false)) {
      events.add(event.copy());
      if (fits()) continue;
      if (frames != null) {
        final heldFrames = frames;
        frames = null;
        if (fits()) continue;
        frames = heldFrames;
      }
      events.removeLast();
      if (events.isNotEmpty) {
        batchFull = true;
        break;
      }
      // A single unsendable item must not permanently pin the queue head.
      _pending.remove(event.key);
    }
    if (!batchFull) {
      for (final operation
          in _pendingOperations.take(20).toList(growable: false)) {
        if (events.length + operations.length >= 20) break;
        operations.add(operation);
        if (fits()) continue;
        if (frames != null) {
          final heldFrames = frames;
          frames = null;
          if (fits()) continue;
          frames = heldFrames;
        }
        operations.removeLast();
        if (events.isNotEmpty || operations.isNotEmpty) {
          break;
        }
        if (_pendingOperations.isNotEmpty &&
            _pendingOperations.first.operationId == operation.operationId) {
          _pendingOperations.removeFirst();
        }
      }
    }
    if (events.isEmpty && operations.isEmpty && frames == null) {
      _inFlight = false;
      return;
    }
    final batch =
        ChatDiagnosticBatch._(_version, _platform, events, frames, operations);
    final abort = Completer<void>();
    _abort = abort;
    _nextAllowed = now.add(const Duration(minutes: 1));
    final deadline = Timer(const Duration(seconds: 5), () {
      if (!abort.isCompleted) abort.complete();
    });
    var success = false;
    int? status;
    try {
      status = await upload(batch, abort.future);
      success = status == 202;
    } catch (_) {
      // Never feed diagnostics transport errors back into diagnostics.
    } finally {
      deadline.cancel();
      _inFlight = false;
      if (identical(_abort, abort)) _abort = null;
    }
    if (epoch != _epoch) return;
    if (status == 422 && operations.isNotEmpty) {
      // An older receiver may know legacy events/frames but not operations.
      _operationsSupported = false;
      _pendingOperations.clear();
    } else if (status == 422 && frames != null) {
      // Old servers have a closed schema. Keep existing events for the next
      // bounded attempt, but stop sending the extension for this session.
      _framesSupported = false;
      _frames = _FrameCounts();
    }
    if (success) {
      _failures = 0;
      if (frames != null) _frames.subtract(frames);
      for (final event in events) {
        final current = _pending[event.key];
        if (current == null) continue;
        current.count -= event.count;
        if (current.count <= 0) _pending.remove(event.key);
      }
      for (final operation in operations) {
        if (_pendingOperations.isNotEmpty &&
            _pendingOperations.first.operationId == operation.operationId) {
          _pendingOperations.removeFirst();
        }
      }
    } else {
      _failures = math.min(_failures + 1, 5);
      final delayMinutes = math.min(1 << (_failures - 1), 15);
      _nextAllowed = _now().add(Duration(minutes: delayMinutes));
    }
  }
}
