import 'dart:async';
import 'network_diagnostics.dart';
import 'network_request_diagnostics.dart';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';

import 'performance_trace_model.dart';
import 'chat_diagnostics_spool_store.dart';
export 'chat_diagnostics_spool_store.dart' show ChatDiagnosticSpoolStore;

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
  refreshResultSuperseded,
  networkRequest;

  String get wireName => switch (this) {
        networkRequest => 'network_request',
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
  ChatDiagnosticLifecycle?,
);

/// The transport must honor abort by closing its independent HTTP connection.
/// Its status is intentionally opaque to auth/session-refresh mechanisms.
typedef ChatDiagnosticUploader = Future<int> Function(
    ChatDiagnosticBatch batch, Future<void> abort);

final class ChatDiagnosticBatch {
  ChatDiagnosticBatch._(
    this.version,
    this.platform,
    List<_Event> events,
    this._frames,
    List<_QueuedPerformanceOperation> operations, {
    bool operationExtensionsSupported = true,
    List<NetworkDiagnosticSnapshot> networks = const [],
    List<NetworkRequestDiagnosticSnapshot> networkRequests = const [],
  })  : _events = List.unmodifiable(events.map((e) => e.copy())),
        _networks = List.unmodifiable(networks),
        _networkRequests = List.unmodifiable(networkRequests),
        _operationExtensionsSupported = operationExtensionsSupported,
        _operations =
            List.unmodifiable(operations.map((entry) => entry.record));
  final String version;
  final ChatDiagnosticPlatform platform;
  final List<_Event> _events;
  final _FrameCounts? _frames;
  final List<PerformanceDiagnosticOperation> _operations;
  final List<NetworkDiagnosticSnapshot> _networks;
  final List<NetworkRequestDiagnosticSnapshot> _networkRequests;
  final bool _operationExtensionsSupported;
  Map<String, Object?> toJson() => {
        'version': version,
        'platform': platform.name,
        'events': [for (final event in _events) event.toJson()],
        if (_networks.isNotEmpty)
          'networks': [for (final sample in _networks) sample.toJson()],
        if (_networkRequests.isNotEmpty)
          'network_requests': [
            for (final request in _networkRequests) request.toJson()
          ],
        if (_frames != null) 'frames': _frames!.toJson(),
        if (_operations.isNotEmpty)
          'operations': [
            for (final operation in _operations)
              _operationWireJson(operation, _operationExtensionsSupported),
          ],
      };
}

/// Local delivery identity is independent of the shared correlation ID.
/// Immutable entries survive spool restoration; this UUID never enters wire JSON.
final class _QueuedPerformanceOperation {
  _QueuedPerformanceOperation(
    this.record, {
    String? queueEntryId,
    required this.retentionPriority,
  }) : queueEntryId = queueEntryId ?? const Uuid().v4();

  final String queueEntryId;
  final PerformanceDiagnosticOperation record;
  final int retentionPriority;
}

/// FIFO delivery with constant-time admission/eviction indexes. Only entries
/// in the actual upload snapshot are frozen; an old backlog is not protected.
final class _PerformanceOperationQueue
    extends IterableBase<_QueuedPerformanceOperation> {
  final _entries = <String, _QueuedPerformanceOperation>{};
  final _evictable = List.generate(
    3,
    (_) => <String, _QueuedPerformanceOperation>{},
  );

  @override
  Iterator<_QueuedPerformanceOperation> get iterator =>
      _entries.values.iterator;
  @override
  int get length => _entries.length;
  @override
  bool get isEmpty => _entries.isEmpty;
  @override
  bool get isNotEmpty => _entries.isNotEmpty;
  @override
  _QueuedPerformanceOperation get first => _entries.values.first;

  void addLast(_QueuedPerformanceOperation entry) {
    _entries[entry.queueEntryId] = entry;
    _evictable[entry.retentionPriority][entry.queueEntryId] = entry;
  }

  void remove(_QueuedPerformanceOperation entry) {
    if (!identical(_entries[entry.queueEntryId], entry)) return;
    _entries.remove(entry.queueEntryId);
    _evictable[entry.retentionPriority].remove(entry.queueEntryId);
  }

  void removeFirst() => remove(first);

  bool evictAtPriority(int priority) {
    final candidates = _evictable[priority];
    if (candidates.isNotEmpty) {
      remove(candidates.values.first);
      return true;
    }
    return false;
  }

  void freeze(List<_QueuedPerformanceOperation> batch) {
    for (final entry in batch) {
      if (identical(_entries[entry.queueEntryId], entry)) {
        _evictable[entry.retentionPriority].remove(entry.queueEntryId);
      }
    }
  }

  // Rebuild chronological indexes only on the deferred upload path, never
  // while recording. This visits at most the existing 100-entry capacity.
  void releaseFrozen() {
    for (final tier in _evictable) {
      tier.clear();
    }
    for (final entry in _entries.values) {
      _evictable[entry.retentionPriority][entry.queueEntryId] = entry;
    }
  }

  void removeWhere(bool Function(_QueuedPerformanceOperation) predicate) {
    for (final entry in _entries.values.toList(growable: false)) {
      if (predicate(entry)) remove(entry);
    }
  }

  void clear() {
    _entries.clear();
    for (final tier in _evictable) {
      tier.clear();
    }
  }
}

bool _hasOperationExtension(_QueuedPerformanceOperation entry) {
  final record = entry.record;
  return record is PerformanceRecord &&
      (record.attemptIndex != null ||
          record.windowIndex != null ||
          record.networkError == PerformanceNetworkError.requestTimeout);
}

Map<String, Object?> _operationWireJson(
  PerformanceDiagnosticOperation operation,
  bool extensionsSupported,
) {
  final json = operation.toJson();
  if (!extensionsSupported && operation is PerformanceRecord) {
    json.remove('attempt_index');
    json.remove('window_index');
    if (operation.networkError == PerformanceNetworkError.requestTimeout) {
      // An older schema cannot express the measured generic deadline. Do not
      // relabel it as DNS/connect/read timeout or infer a network phase.
      json['network_error'] = PerformanceNetworkError.unknown.wireName;
    }
  }
  return json;
}

final class _FrameCounts {
  static _FrameCounts? tryParse(Object? value) {
    const keys = {
      'frame_count',
      'slow_frame_count',
      'slow_build_count',
      'slow_raster_count',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !value.keys.every(keys.contains) ||
        !value.values.every((n) => n is int && n >= 0 && n <= 1000000)) {
      return null;
    }
    final total = value['frame_count'] as int,
        slow = value['slow_frame_count'] as int,
        build = value['slow_build_count'] as int,
        raster = value['slow_raster_count'] as int;
    if (total == 0 ||
        slow > total ||
        build > slow ||
        raster > slow ||
        slow > build + raster) {
      return null;
    }
    return _FrameCounts()
      ..total = total
      ..slow = slow
      ..build = build
      ..raster = raster;
  }

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
  static _Event? tryParse(Map<String, dynamic> raw) {
    if (raw.keys.any(
      (key) => !const {
        'operation_id',
        'stage',
        'error',
        'elapsed_ms',
        'count',
        'status',
        'retry_count',
        'lifecycle',
      }.contains(key),
    )) {
      return null;
    }
    final stages = ChatDiagnosticStage.values.where(
      (v) => v.wireName == raw['stage'],
    );
    final errors = ChatDiagnosticError.values.where(
      (v) => v.name == raw['error'],
    );
    final id = raw['operation_id'],
        elapsed = raw['elapsed_ms'],
        count = raw['count'];
    final status = raw['status'], retry = raw['retry_count'];
    final lifecycle = ChatDiagnosticLifecycle.values.where(
      (v) => v.name == raw['lifecycle'],
    );
    if (stages.isEmpty ||
        errors.isEmpty ||
        id is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id) ||
        elapsed is! int ||
        elapsed < 0 ||
        elapsed > 3600000 ||
        count is! int ||
        count < 1 ||
        count > 1000000 ||
        (status != null && (status is! int || status < 100 || status > 599)) ||
        (retry != null && (retry is! int || retry < 0 || retry > 20)) ||
        (raw['lifecycle'] != null && lifecycle.isEmpty)) {
      return null;
    }
    return _Event(
      stages.first,
      errors.first,
      status as int?,
      elapsed,
      count,
      operationId: id,
      retryCount: retry as int?,
      lifecycle: lifecycle.isEmpty ? null : lifecycle.first,
    );
  }

  _Event(
    this.stage,
    this.error,
    this.status,
    this.elapsedMs,
    this.count, {
    String? operationId,
    this.retryCount,
    this.lifecycle,
  }) : operationId = operationId ?? const Uuid().v4();
  final ChatDiagnosticStage stage;
  final ChatDiagnosticError error;
  final int? status;
  final String operationId;
  final int? retryCount;
  final ChatDiagnosticLifecycle? lifecycle;
  int elapsedMs;
  int count;
  _EventKey get key => (stage, error, status, retryCount, lifecycle);
  _Event copy() => _Event(
        stage,
        error,
        status,
        elapsedMs,
        count,
        operationId: operationId,
        retryCount: retryCount,
        lifecycle: lifecycle,
      );
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

/// Closed metadata with an optional bounded, account-isolated local spool.
/// Callers cannot submit text, identifiers or stacks.
/// Recording is bounded O(1), never awaits, and never writes on the UI path.
final class ChatDiagnostics {
  static const maxSpoolBytes = 64 * 1024;
  static const spoolExpiry = Duration(hours: 24);
  static const _serverBodyLimitBytes = 16 * 1024;
  static const defaultMaxUploadBytes = 15 * 1024;

  ChatDiagnostics({
    DateTime Function()? now,
    this.normalSamplePercent = PerformanceThresholds.normalSamplePercent,
    this.maxUploadBytes = defaultMaxUploadBytes,
  }) : _now = now ?? DateTime.now {
    networks = NetworkDiagnostics(
        now: now,
        retainedRequestCount: () => _regionalBackfill.fold<int>(
            0, (sum, batch) => sum + batch._networkRequests.length));
    if (normalSamplePercent < 0 || normalSamplePercent > 100) {
      throw ArgumentError.value(normalSamplePercent, 'normalSamplePercent');
    }
    if (maxUploadBytes < 256 || maxUploadBytes > _serverBodyLimitBytes) {
      throw ArgumentError.value(maxUploadBytes, 'maxUploadBytes');
    }
  }
  static ChatDiagnostics instance = ChatDiagnostics();
  final DateTime Function() _now;
  late final NetworkDiagnostics networks;
  final _regionalBackfill = <ChatDiagnosticBatch>[];
  int _reportedNetworkDrops = 0;
  final int normalSamplePercent;
  final int maxUploadBytes;
  final _pending = <_EventKey, _Event>{};
  final _pendingOperations = _PerformanceOperationQueue();
  final _evictableEventKeys = List.generate(
    3,
    (_) => LinkedHashSet<_EventKey>(),
  );
  _FrameCounts _frames = _FrameCounts();
  _FrameCounts _cumulativeFrames = _FrameCounts();
  bool _framesSupported = true;
  bool _operationsSupported = true;
  bool _observationsSupported = true;
  bool _operationExtensionsSupported = true;
  ChatDiagnosticUploader? _upload;
  String _version = '';
  ChatDiagnosticPlatform _platform = ChatDiagnosticPlatform.other;
  Timer? _timer;
  Completer<void>? _abort;
  bool _inFlight = false;
  int _epoch = 0;
  int _failures = 0;
  DateTime? _nextAllowed;
  ChatDiagnosticSpoolStore? _spool;
  Future<String?>? _spoolScope;
  bool _spoolRunning = false;
  ({
    ChatDiagnosticSpoolStore store,
    Future<String?> scope,
    List<_Event> events,
    List<_QueuedPerformanceOperation> operations,
    List<NetworkDiagnosticSnapshot> networks,
    List<NetworkRequestDiagnosticSnapshot> networkRequests,
    List<Map<String, Object?>> regional,
    String version,
    String platform,
    _FrameCounts frames,
    DateTime created,
    int epoch,
  })? _spoolWrite;
  ({
    ChatDiagnosticSpoolStore store,
    Future<String?> scope,
    int epoch
  })? _spoolRestore;
  Timer? _spoolTimer;
  bool _restoring = false;
  DateTime? _spoolCreated;
  bool _networkStageSupported = true;
  int get pendingCount =>
      _pending.length +
      _pendingOperations.length +
      _regionalBackfill.fold<int>(
        0,
        (sum, batch) => sum + batch._events.length,
      );
  bool get isActive => _upload != null;
  PerformanceFrameCounts get cumulativeFrameCounts => PerformanceFrameCounts(
        total: _cumulativeFrames.total,
        slow: _cumulativeFrames.slow,
        slowBuild: _cumulativeFrames.build,
        slowRaster: _cumulativeFrames.raster,
      );

  /// Capture before an async operation; discard its diagnostic after logout.
  int get sessionGeneration => _epoch;

  void startSession({
    required String version,
    required ChatDiagnosticPlatform platform,
    required ChatDiagnosticUploader upload,
    ChatDiagnosticSpoolStore? store,
    Future<String?> Function()? spoolScope,
  }) {
    stopSession();
    if (!RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$').hasMatch(version)) {
      return;
    }
    _version = version;
    _platform = platform;
    _upload = upload;
    networks.start(
      version: version,
      platform: platform.name,
      generation: _epoch,
    );
    _spool = store;
    _spoolCreated = _now();
    if (store != null && spoolScope != null) {
      _spoolScope = Future.sync(spoolScope).then(
        (value) => value != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
            ? value
            : null,
        onError: (Object _, StackTrace __) => null,
      );
      _restoreSpool();
    }
    _nextAllowed = _now().add(const Duration(minutes: 1));
    _timer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(flush()),
    );
  }

  void stopSession() {
    _spoolTimer?.cancel();
    _queueSpoolWrite(finalNetworkWindow: true);
    _spool = null;
    _spoolScope = null;
    _restoring = false;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _upload = null;
    _pending.clear();
    _pendingOperations.clear();
    _regionalBackfill.clear();
    networks.clear();
    _reportedNetworkDrops = 0;
    for (final tier in _evictableEventKeys) {
      tier.clear();
    }
    _frames = _FrameCounts();
    _cumulativeFrames = _FrameCounts();
    _framesSupported = true;
    _operationsSupported = true;
    _observationsSupported = true;
    _operationExtensionsSupported = true;
    _networkStageSupported = true;
    _failures = 0;
    _nextAllowed = null;
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    // Do not release _inFlight here: the old transport must actually finish.
  }

  void record({
    required ChatDiagnosticStage stage,
    required ChatDiagnosticError error,
    Duration elapsed = Duration.zero,
    int count = 1,
    int? status,
    int? retryCount,
    ChatDiagnosticLifecycle? lifecycle,
  }) {
    if (_upload == null ||
        (error == ChatDiagnosticError.slow && elapsed.inMilliseconds < 250)) {
      return;
    }
    if (stage == ChatDiagnosticStage.networkRequest &&
        !_networkStageSupported) {
      return;
    }
    _beginPendingRecord();
    _scheduleSpoolWrite();
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
    final event = _Event(
      stage,
      error,
      safeStatus,
      ms,
      safeCount,
      retryCount: safeRetryCount,
      lifecycle: lifecycle,
    );
    if (pendingCount >= 100 && !_makeRoomAtMost(_eventPriority(event))) return;
    _addPendingEvent(event);
  }

  /// Foreground frames only (enforced by the scope). A slow frame exceeds
  /// either pipeline stage's display budget; totalSpan is not a drop count.
  void recordFrame({
    required int buildUs,
    required int rasterUs,
    required int budgetUs,
  }) {
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
    _admitPerformance(record, mustKeep: _mustKeepPerformance(record));
  }

  /// A partial observation has no final result. Keep checkpoints and expired
  /// evidence in the established bounded queue without normal-event sampling.
  void recordObservation(PerformanceTraceObservation observation) {
    if (_upload == null || !_operationsSupported || !_observationsSupported) {
      return;
    }
    _admitPerformance(observation, mustKeep: true);
  }

  void _admitPerformance(
    PerformanceDiagnosticOperation record, {
    required bool mustKeep,
  }) {
    _expirePending();
    if (!mustKeep) {
      var hash = 0;
      for (final code in record.operationId.codeUnits) {
        hash = ((hash * 31) + code) & 0x7fffffff;
      }
      if (hash % 100 >= normalSamplePercent) return;
    }
    final priority = _retentionPriority(record, mustKeep: mustKeep);
    if (pendingCount >= 100 && !_makeRoomAtMost(priority)) {
      return;
    }
    _beginPendingRecord();
    _pendingOperations.addLast(
      _QueuedPerformanceOperation(record, retentionPriority: priority),
    );
    _scheduleSpoolWrite();
  }

  int _retentionPriority(
    PerformanceDiagnosticOperation record, {
    required bool mustKeep,
  }) =>
      switch (record) {
        PerformanceTraceObservation(kind: PerformanceObservationKind.expired) =>
          2,
        PerformanceTraceObservation() => 1,
        PerformanceRecord(
          result: PerformanceResult.failed ||
              PerformanceResult.rejected ||
              PerformanceResult.waitingNetwork ||
              PerformanceResult.cancelled,
        ) =>
          2,
        _ => mustKeep ? 1 : 0,
      };

  bool _makeRoomAtMost(int priority) {
    for (var tier = 0; tier <= priority; tier++) {
      if (_pendingOperations.evictAtPriority(tier)) return true;
      final keys = _evictableEventKeys[tier];
      if (keys.isNotEmpty) {
        _removePendingEvent(keys.first);
        return true;
      }
    }
    return false;
  }

  int _eventPriority(_Event event) => event.error == ChatDiagnosticError.slow ||
          event.error == ChatDiagnosticError.recovered
      ? 1
      : 2;

  void _addPendingEvent(_Event event) {
    _pending[event.key] = event;
    _evictableEventKeys[_eventPriority(event)].add(event.key);
  }

  void _removePendingEvent(_EventKey key) {
    final event = _pending.remove(key);
    if (event != null) {
      _evictableEventKeys[_eventPriority(event)].remove(key);
    }
  }

  void _releaseFrozenEvents() {
    for (final tier in _evictableEventKeys) {
      tier.clear();
    }
    for (final event in _pending.values) {
      _evictableEventKeys[_eventPriority(event)].add(event.key);
    }
  }

  bool _mustKeepPerformance(PerformanceRecord record) {
    if (record.result != PerformanceResult.success) return true;
    if (record.frameAttributionComplete &&
        record.frames.slow >= PerformanceThresholds.slowFrameCountWarning) {
      return true;
    }
    if (record.operation == PerformanceOperationType.conversationOpen) {
      final firstFrame = record.betweenMs(
        PerformanceStage.routePushStarted,
        PerformanceStage.firstFrameRendered,
      );
      final localReady = record.betweenMs(
        PerformanceStage.userAction,
        PerformanceStage.localTimelineReady,
      );
      final syncWait = record.conversationSyncWaitMs;
      final responseWait = record.betweenMs(
        PerformanceStage.syncResponseWaitStarted,
        PerformanceStage.syncResponseReceived,
      );
      final processing = record.betweenMs(
        PerformanceStage.syncResponseReceived,
        PerformanceStage.syncProcessingDone,
      );
      return (firstFrame != null &&
              firstFrame >= PerformanceThresholds.conversationFirstFrameMs) ||
          (localReady != null &&
              localReady >= PerformanceThresholds.conversationLocalReadyMs) ||
          (syncWait != null && syncWait >= PerformanceThresholds.syncWaitMs) ||
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
        PerformanceStage.syncProcessingDone,
      );
      final cleanup = record.betweenMs(
        PerformanceStage.syncProcessingDone,
        PerformanceStage.syncCleanupDone,
      );
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
          (loss != null && loss >= PerformanceThresholds.callPacketLossPercent);
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
    _expirePending();
    final upload = _upload;
    final now = _now();
    if (_regionalBackfill.isNotEmpty &&
        upload != null &&
        !_inFlight &&
        !_restoring &&
        (_nextAllowed == null || !now.isBefore(_nextAllowed!))) {
      await _flushRegionalBackfill(upload);
      return;
    }
    if (upload == null ||
        (_pending.isEmpty &&
            _pendingOperations.isEmpty &&
            _frames.total == 0 &&
            !networks.hasPending &&
            !networks.hasPendingRequests) ||
        _inFlight ||
        _restoring ||
        (_nextAllowed != null && now.isBefore(_nextAllowed!))) {
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final events = <_Event>[];
    final operations = <_QueuedPerformanceOperation>[];
    final samples = <NetworkDiagnosticSnapshot>[];
    final requests = <NetworkRequestDiagnosticSnapshot>[];
    final waitingSamples = networks.pending();
    _reportNetworkLoss();
    final frameGroup = _frames;
    _FrameCounts? frames = frameGroup.total > 0 ? frameGroup.copy() : null;

    // Encoding happens only on this low-frequency flush path. Count actual
    // UTF-8 body bytes, including JSON framing, below the server's 16 KiB cap.
    bool fits() =>
        utf8
            .encode(
              jsonEncode(
                ChatDiagnosticBatch._(
                  _version,
                  _platform,
                  events,
                  frames,
                  operations,
                  operationExtensionsSupported: _operationExtensionsSupported,
                  networks: samples,
                  networkRequests: requests,
                ).toJson(),
              ),
            )
            .length <=
        maxUploadBytes;

    var batchFull = false;
    for (final event in _pending.values.take(20).toList(growable: false)) {
      events.add(event.copy());
      if (fits()) {
        continue;
      }
      if (frames != null) {
        final heldFrames = frames;
        frames = null;
        if (fits()) {
          continue;
        }
        frames = heldFrames;
      }
      events.removeLast();
      if (events.isNotEmpty) {
        batchFull = true;
        break;
      }
      // A single unsendable item must not permanently pin the queue head.
      _removePendingEvent(event.key);
    }
    if (!batchFull) {
      for (final operation
          in _pendingOperations.take(20).toList(growable: false)) {
        if (events.length + operations.length >= 20) break;
        operations.add(operation);
        if (fits()) {
          continue;
        }
        if (frames != null) {
          final heldFrames = frames;
          frames = null;
          if (fits()) {
            continue;
          }
          frames = heldFrames;
        }
        operations.removeLast();
        if (events.isNotEmpty || operations.isNotEmpty) {
          break;
        }
        if (_pendingOperations.isNotEmpty &&
            identical(_pendingOperations.first, operation)) {
          _pendingOperations.removeFirst();
        }
      }
    }
    for (final sample in waitingSamples) {
      samples.add(sample);
      if (!fits()) {
        samples.removeLast();
        break;
      }
    }
    for (final request in networks.pendingRequests()) {
      if (events.length + operations.length + requests.length >= 20) break;
      requests.add(request);
      if (!fits()) {
        requests.removeLast();
        break;
      }
    }
    if (events.isEmpty &&
        operations.isEmpty &&
        frames == null &&
        samples.isEmpty &&
        requests.isEmpty) {
      _inFlight = false;
      return;
    }
    final batch = ChatDiagnosticBatch._(
      _version,
      _platform,
      events,
      frames,
      operations,
      operationExtensionsSupported: _operationExtensionsSupported,
      networks: samples,
      networkRequests: requests,
    );
    _pendingOperations.freeze(operations);
    for (final event in events) {
      _evictableEventKeys[_eventPriority(event)].remove(event.key);
    }
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
    if (status == 422 && requests.isNotEmpty) {
      _disableRequestExtension();
      _failures = 0;
      _nextAllowed = _now().add(const Duration(minutes: 1));
      _pendingOperations.releaseFrozen();
      _releaseFrozenEvents();
      _queueSpoolWrite();
      return;
    }
    if (status == 422 && samples.isNotEmpty) {
      // Remove only the optional network extension. Retry baseline channels
      // unchanged at their existing cadence, before their own compatibility fallbacks.
      _disableNetworkExtension();
      _failures = 0;
      _nextAllowed = _now().add(const Duration(minutes: 1));
      _pendingOperations.releaseFrozen();
      _releaseFrozenEvents();
      _queueSpoolWrite();
      return;
    }
    if (status == 422 && operations.isNotEmpty) {
      final hasObservation = operations.any(
        (entry) => entry.record is PerformanceTraceObservation,
      );
      final hasNewFields = _operationExtensionsSupported &&
          operations.any(_hasOperationExtension);
      if (hasObservation || hasNewFields) {
        // First remove only the new extension. Preserve baseline final records
        // and retry them at the existing cadence with their immutable identity.
        if (hasObservation) {
          _observationsSupported = false;
          _pendingOperations.removeWhere(
            (entry) => entry.record is PerformanceTraceObservation,
          );
        }
        if (hasNewFields) _operationExtensionsSupported = false;
      } else {
        // An older receiver may know events/frames but no baseline operations.
        _operationsSupported = false;
        _pendingOperations.clear();
      }
    } else if (status == 422 && frames != null) {
      // Old servers have a closed schema. Keep existing events for the next
      // bounded attempt, but stop sending the extension for this session.
      _framesSupported = false;
      _frames = _FrameCounts();
    }
    if (status == 422 &&
        operations.isEmpty &&
        frames == null &&
        events.any(
          (event) => event.stage == ChatDiagnosticStage.networkRequest,
        )) {
      // Only this newly introduced stage is incompatible. Preserve legacy
      // events for a later supported batch; never drop an entire mixed batch.
      _networkStageSupported = false;
      _pending.removeWhere(
        (key, _) => key.$1 == ChatDiagnosticStage.networkRequest,
      );
    }
    if (success) {
      networks.acknowledge(samples);
      networks.acknowledgeRequests(requests);
      _failures = 0;
      if (frames != null && identical(_frames, frameGroup)) {
        _frames.subtract(frames);
      }
      for (final event in events) {
        final current = _pending[event.key];
        if (current == null || current.operationId != event.operationId) {
          continue;
        }
        current.count -= event.count;
        if (current.count <= 0) _removePendingEvent(event.key);
      }
      for (final operation in operations) {
        _pendingOperations.remove(operation);
      }
    } else {
      _failures = math.min(_failures + 1, 5);
      final delayMinutes = math.min(1 << (_failures - 1), 15);
      _nextAllowed = _now().add(Duration(minutes: delayMinutes));
    }
    _pendingOperations.releaseFrozen();
    _releaseFrozenEvents();
    _queueSpoolWrite();
  }

  void _reportNetworkLoss() {
    final lost = networks.droppedAttempts +
        networks.droppedRequests -
        _reportedNetworkDrops;
    if (lost <= 0) return;
    record(
      stage: ChatDiagnosticStage.networkRequest,
      error: ChatDiagnosticError.incomplete,
      count: lost,
    );
    _reportedNetworkDrops = networks.droppedAttempts + networks.droppedRequests;
  }

  void _disableRequestExtension() {
    networks.disableRequests();
    for (var i = 0; i < _regionalBackfill.length; i++) {
      final old = _regionalBackfill[i];
      _regionalBackfill[i] = ChatDiagnosticBatch._(
        old.version,
        old.platform,
        old._events,
        old._frames,
        const [],
        networks: old._networks,
      );
    }
    _regionalBackfill.removeWhere(
        (b) => b._events.isEmpty && b._frames == null && b._networks.isEmpty);
  }

  void _disableNetworkExtension() {
    networks.disable();
    for (var i = 0; i < _regionalBackfill.length; i++) {
      final old = _regionalBackfill[i];
      _regionalBackfill[i] = ChatDiagnosticBatch._(
        old.version,
        old.platform,
        old._events,
        old._frames,
        const [],
        networkRequests: old._networkRequests,
      );
    }
    _regionalBackfill.removeWhere(
      (b) =>
          b._events.isEmpty && b._frames == null && b._networkRequests.isEmpty,
    );
  }

  void _restoreRegional(Map<String, dynamic> raw) {
    final version = raw['version'];
    final platforms = ChatDiagnosticPlatform.values.where(
      (p) => p.name == raw['platform'],
    );
    if (version is! String ||
        !RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$').hasMatch(version) ||
        platforms.isEmpty) {
      return;
    }
    final events = <_Event>[];
    if (raw['events'] is List) {
      for (final value in (raw['events'] as List).take(100)) {
        if (value is Map<String, dynamic>) {
          final event = _Event.tryParse(value);
          if (event != null) events.add(event);
        }
      }
    }
    final samples = <NetworkDiagnosticSnapshot>[];
    if (raw['networks'] is List) {
      for (final value in (raw['networks'] as List).take(
        NetworkDiagnostics.maximumSnapshots,
      )) {
        final sample = NetworkDiagnosticSnapshot.tryParse(value);
        if (sample != null &&
            !samples.any((s) => s.sampleId == sample.sampleId)) {
          samples.add(sample);
        }
      }
    }
    var frames = _FrameCounts.tryParse(raw['frames']);
    final requests = <NetworkRequestDiagnosticSnapshot>[];
    final requestSlots = NetworkDiagnostics.maximumRequests -
        networks.forRequestPersistence().length -
        _regionalBackfill.fold<int>(
            0, (sum, batch) => sum + batch._networkRequests.length);
    if (raw['network_requests'] is List) {
      for (final value in (raw['network_requests'] as List)
          .take(requestSlots.clamp(0, 64))) {
        final request = NetworkRequestDiagnosticSnapshot.tryParse(value);
        if (request != null &&
            !requests.any((r) => r.requestId == request.requestId)) {
          requests.add(request);
        }
      }
    }
    while ((events.isNotEmpty ||
            samples.isNotEmpty ||
            requests.isNotEmpty ||
            frames != null) &&
        _regionalBackfill.length < 16) {
      final selectedEvents = events.take(20).toList();
      final selectedSamples = samples.take(8).toList();
      final selectedRequests =
          requests.take(math.min(8, 20 - selectedEvents.length)).toList();
      _regionalBackfill.add(
        ChatDiagnosticBatch._(
          version,
          platforms.first,
          selectedEvents,
          frames,
          const [],
          networks: selectedSamples,
          networkRequests: selectedRequests,
        ),
      );
      events.removeRange(0, selectedEvents.length);
      samples.removeRange(0, selectedSamples.length);
      requests.removeRange(0, selectedRequests.length);
      frames = null;
    }
  }

  Future<void> _flushRegionalBackfill(ChatDiagnosticUploader upload) async {
    final old = _regionalBackfill.first;
    final events = List<_Event>.of(old._events);
    final samples = List<NetworkDiagnosticSnapshot>.of(old._networks);
    final requests =
        List<NetworkRequestDiagnosticSnapshot>.of(old._networkRequests);
    var frames = old._frames;
    ChatDiagnosticBatch snapshot() => ChatDiagnosticBatch._(
          old.version,
          old.platform,
          events,
          frames,
          const [],
          networks: samples,
          networkRequests: requests,
        );
    bool fits() =>
        utf8.encode(jsonEncode(snapshot().toJson())).length <= maxUploadBytes;
    while (!fits()) {
      if (requests.isNotEmpty) {
        requests.removeLast();
      } else if (samples.isNotEmpty) {
        samples.removeLast();
      } else if (events.isNotEmpty) {
        events.removeLast();
      } else {
        frames = null;
      }
    }
    if (events.isEmpty &&
        samples.isEmpty &&
        requests.isEmpty &&
        frames == null) {
      // Default batches are always smaller than the receiver budget. A caller
      // with a smaller custom budget must still be able to advance its queue.
      _regionalBackfill.removeAt(0);
      _queueSpoolWrite();
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final abort = Completer<void>();
    _abort = abort;
    _nextAllowed = _now().add(const Duration(minutes: 1));
    final deadline = Timer(const Duration(seconds: 5), () {
      if (!abort.isCompleted) abort.complete();
    });
    int? status;
    try {
      status = await upload(snapshot(), abort.future);
    } catch (_) {
      /* Diagnostics must never fail business requests. */
    } finally {
      deadline.cancel();
      _inFlight = false;
      if (identical(_abort, abort)) _abort = null;
    }
    if (epoch != _epoch) return;
    if (status == 202) {
      final remainingEvents = old._events.skip(events.length).toList();
      final remainingSamples = old._networks.skip(samples.length).toList();
      final remainingRequests =
          old._networkRequests.skip(requests.length).toList();
      final remainingFrames = frames == null ? old._frames : null;
      _regionalBackfill.removeAt(0);
      if (remainingEvents.isNotEmpty ||
          remainingSamples.isNotEmpty ||
          remainingRequests.isNotEmpty ||
          remainingFrames != null) {
        _regionalBackfill.insert(
          0,
          ChatDiagnosticBatch._(
            old.version,
            old.platform,
            remainingEvents,
            remainingFrames,
            const [],
            networks: remainingSamples,
            networkRequests: remainingRequests,
          ),
        );
      }
      _failures = 0;
    } else if (status == 422 && requests.isNotEmpty) {
      _disableRequestExtension();
      _failures = 0;
    } else if (status == 422 && samples.isNotEmpty) {
      _disableNetworkExtension();
      _failures = 0;
    } else if (status == 422 && frames != null) {
      _framesSupported = false;
      _frames = _FrameCounts();
      for (var i = 0; i < _regionalBackfill.length; i++) {
        final b = _regionalBackfill[i];
        _regionalBackfill[i] = ChatDiagnosticBatch._(
          b.version,
          b.platform,
          b._events,
          null,
          const [],
          networks: b._networks,
          networkRequests: b._networkRequests,
        );
      }
    } else {
      _failures = math.min(_failures + 1, 5);
      _nextAllowed = _now().add(
        Duration(minutes: math.min(1 << (_failures - 1), 15)),
      );
    }
    _queueSpoolWrite();
  }

  void _expirePending() {
    final created = _spoolCreated;
    if (created != null && _now().difference(created) > spoolExpiry) {
      _pending.clear();
      _pendingOperations.clear();
      _regionalBackfill.clear();
      networks.acknowledge(networks.persisted);
      networks.acknowledgeRequests(networks.forRequestPersistence());
      for (final tier in _evictableEventKeys) {
        tier.clear();
      }
      _frames = _FrameCounts();
      _spoolCreated = null;
    }
  }

  void _beginPendingRecord() {
    _expirePending();
    if (_pending.isEmpty &&
        _pendingOperations.isEmpty &&
        _regionalBackfill.isEmpty &&
        !networks.hasPending &&
        !networks.hasPendingRequests) {
      _spoolCreated = _now();
    }
  }

  // record() only creates one timer. Encoding, local I/O and bounded decoding
  // run on this deferred worker. At most one I/O and one trailing snapshot.
  void _scheduleSpoolWrite() {
    if (_spool == null || _spoolTimer?.isActive == true) return;
    _spoolTimer = Timer(const Duration(seconds: 1), _queueSpoolWrite);
  }

  void _queueSpoolWrite({bool finalNetworkWindow = false}) {
    _spoolTimer?.cancel();
    final store = _spool;
    final scope = _spoolScope;
    if (store == null || scope == null) return;
    final networkSamples = networks.forPersistence(
      finalWindow: finalNetworkWindow,
    );
    _reportNetworkLoss();
    _spoolWrite = (
      store: store,
      scope: scope,
      events: [for (final e in _pending.values) e.copy()],
      operations: _pendingOperations.toList(growable: false),
      networks: networkSamples,
      networkRequests: networks.forRequestPersistence(),
      regional: [for (final batch in _regionalBackfill) batch.toJson()],
      version: _version,
      platform: _platform.name,
      frames: _frames.copy(),
      created: _spoolCreated ?? _now(),
      epoch: _epoch,
    );
    _runSpoolWork();
  }

  void _restoreSpool() {
    final store = _spool;
    final scope = _spoolScope;
    if (store == null || scope == null) return;
    _restoring = true;
    _spoolRestore = (store: store, scope: scope, epoch: _epoch);
    _runSpoolWork();
  }

  void _runSpoolWork() {
    if (_spoolRunning) return;
    _spoolRunning = true;
    unawaited(() async {
      try {
        while (_spoolWrite != null || _spoolRestore != null) {
          // An old-account write finishes before restore. A new-session
          // snapshot must wait until restore merged that account's backlog.
          final write = _spoolRestore != null &&
                  _spoolWrite != null &&
                  _spoolWrite!.epoch >= _spoolRestore!.epoch
              ? null
              : _spoolWrite;
          if (write != null) {
            _spoolWrite = null;
            try {
              final scope = await write.scope;
              if (scope == null) {
                continue;
              }
              if (write.events.isEmpty &&
                      write.operations.isEmpty &&
                      write.networks.isEmpty &&
                      write.networkRequests.isEmpty &&
                      write.regional.isEmpty &&
                      write.frames.total == 0 ||
                  _now().difference(write.created) > spoolExpiry) {
                await write.store.clear();
                continue;
              }
              final events = <Map<String, Object?>>[];
              final operations = <Map<String, Object?>>[];
              final samples = <Map<String, Object?>>[];
              final requests = <Map<String, Object?>>[];
              final regional = <Map<String, Object?>>[];
              final body = <String, Object?>{
                'schema': 3,
                'scope': scope,
                'created_ms': write.created.millisecondsSinceEpoch,
                'source_version': write.version,
                'source_platform': write.platform,
                'networks': samples,
                if (write.networkRequests.isNotEmpty)
                  'network_requests': requests,
                'regional_backfill': regional,
                'events': events,
                'operations': operations,
                'frames': write.frames.toJson(),
              };
              // Encode each candidate once, stopping at the oldest bounded
              // prefix. Whole-payload encoding then sees at most 64 KiB;
              // never re-encode 100 large operations while removing one tail.
              var bytes = utf8.encode(jsonEncode(body)).length;
              bool append(
                List<Map<String, Object?>> target,
                Map<String, Object?> item,
              ) {
                final extra = utf8.encode(jsonEncode(item)).length +
                    (target.isEmpty ? 0 : 1);
                if (bytes + extra > maxSpoolBytes) return false;
                bytes += extra;
                target.add(item);
                return true;
              }

              for (final event in write.events) {
                if (!append(events, event.toJson())) break;
              }
              for (final batch in write.regional) {
                if (!append(regional, batch)) break;
              }
              for (final sample in write.networks) {
                if (!append(samples, sample.toJson())) break;
              }
              for (final request in write.networkRequests) {
                if (!append(requests, request.toJson())) break;
              }
              for (final entry in write.operations) {
                final operation = entry.record;
                if (!append(operations, {
                  'queue_entry_id': entry.queueEntryId,
                  ...operation.toJson(),
                  if (operation is PerformanceTraceObservation)
                    'observed_idle_ms': (operation.idleUs ~/ 1000).clamp(
                      0,
                      3600000,
                    ),
                  if (operation is PerformanceRecord) ...{
                    'frames_total': operation.frames.total,
                    if (operation.packetsLost != null)
                      'packets_lost': operation.packetsLost,
                    if (operation.packetsReceived != null)
                      'packets_received': operation.packetsReceived,
                  },
                })) {
                  break;
                }
              }
              final payload = jsonEncode(body);
              await write.store.write(payload);
            } catch (_) {
              /* Metadata storage must never fail business work. */
            }
            continue;
          }
          final restore = _spoolRestore!;
          _spoolRestore = null;
          bool current() =>
              restore.epoch == _epoch && identical(restore.store, _spool);
          try {
            final scope = await restore.scope;
            if (!current() || scope == null) {
              continue;
            }
            final raw = await restore.store.read();
            if (!current() || raw == null) {
              continue;
            }
            // UTF-16 length preflight bounds allocation before UTF-8/decode.
            if (raw.length > maxSpoolBytes ||
                utf8.encode(raw).length > maxSpoolBytes) {
              await restore.store.clear();
              continue;
            }
            final decoded = jsonDecode(raw);
            if (decoded is! Map ||
                (decoded['schema'] != 2 && decoded['schema'] != 3) ||
                decoded['scope'] != scope ||
                decoded['created_ms'] is! int) {
              await restore.store.clear();
              continue;
            }
            final created = DateTime.fromMillisecondsSinceEpoch(
              decoded['created_ms'] as int,
            );
            final age = _now().difference(created);
            if (age.isNegative || age > spoolExpiry) {
              await restore.store.clear();
              continue;
            }
            _spoolCreated = created;
            final backlog = decoded['regional_backfill'];
            if (backlog is List) {
              for (final item in backlog.take(16)) {
                if (item is Map<String, dynamic>) _restoreRegional(item);
              }
            }
            final sourceVersion = decoded['source_version'];
            final sourcePlatform = decoded['source_platform'];
            if (sourceVersion is String && sourcePlatform is String) {
              if (sourceVersion == _version &&
                  sourcePlatform == _platform.name) {
                final samples = decoded['networks'];
                if (samples is List) {
                  for (final item in samples.take(32)) {
                    if (item is! Map<String, dynamic>) continue;
                    final sample = NetworkDiagnosticSnapshot.tryParse(item);
                    if (sample != null) networks.restore(sample);
                  }
                }
                final requests = decoded['network_requests'];
                if (requests is List) {
                  for (final item in requests.take(64)) {
                    final request =
                        NetworkRequestDiagnosticSnapshot.tryParse(item);
                    if (request != null) networks.restoreRequest(request);
                  }
                }
              } else {
                _restoreRegional({
                  'version': sourceVersion,
                  'platform': sourcePlatform,
                  'events': decoded['events'],
                  'frames': decoded['frames'],
                  'networks': decoded['networks'],
                  'network_requests': decoded['network_requests'],
                });
                // Preserve past releases' envelopes; current-release records
                // retain the existing scoped-spool coalescing behavior.
                decoded['events'] = <Object>[];
                decoded['frames'] = null;
              }
            }
            final events = decoded['events'];
            if (events is List) {
              for (final item in events.take(100)) {
                if (pendingCount >= 100) break;
                if (item is! Map ||
                    item.keys.any(
                      (key) => !const {
                        'operation_id',
                        'stage',
                        'error',
                        'elapsed_ms',
                        'count',
                        'status',
                        'retry_count',
                        'lifecycle',
                      }.contains(key),
                    )) {
                  continue;
                }
                final elapsed = item['elapsed_ms'], count = item['count'];
                if (elapsed is! int ||
                    elapsed < 0 ||
                    elapsed > 3600000 ||
                    count is! int ||
                    count < 1 ||
                    count > 1000000) {
                  continue;
                }
                ChatDiagnosticStage? stage;
                ChatDiagnosticError? error;
                for (final v in ChatDiagnosticStage.values) {
                  if (v.wireName == item['stage']) stage = v;
                }
                for (final v in ChatDiagnosticError.values) {
                  if (v.name == item['error']) error = v;
                }
                if (stage == null || error == null) {
                  continue;
                }
                // Retain UUID only after strict validation. Unknown raw labels,
                // payloads and identifiers never enter the typed collection.
                final id = item['operation_id'];
                if (id is! String ||
                    !RegExp(
                      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
                    ).hasMatch(id)) {
                  continue;
                }
                final status = item['status'];
                final retry = item['retry_count'];
                if (status != null &&
                        (status is! int || status < 100 || status > 599) ||
                    retry != null &&
                        (retry is! int || retry < 0 || retry > 20)) {
                  continue;
                }
                ChatDiagnosticLifecycle? lifecycle;
                for (final v in ChatDiagnosticLifecycle.values) {
                  if (v.name == item['lifecycle']) lifecycle = v;
                }
                if (item['lifecycle'] != null && lifecycle == null) {
                  continue;
                }
                final e = _Event(
                  stage,
                  error,
                  status is int && status >= 100 && status <= 599
                      ? status
                      : null,
                  elapsed,
                  count,
                  operationId: id,
                  retryCount: retry as int?,
                  lifecycle: lifecycle,
                );
                final existing = _pending[e.key];
                if (existing == null) {
                  _addPendingEvent(e);
                } else {
                  existing.count = (existing.count + e.count).clamp(1, 1000000);
                  existing.elapsedMs = math.max(
                    existing.elapsedMs,
                    e.elapsedMs,
                  );
                }
              }
            }
            final operations = decoded['operations'];
            if (operations is List) {
              final restoredIds = {
                for (final entry in _pendingOperations) entry.queueEntryId,
              };
              for (final rawOperation in operations.take(100)) {
                if (pendingCount >= 100) break;
                final restored = restoreDiagnosticQueueOperation(
                  rawOperation,
                  schema: decoded['schema'] as int,
                );
                if (restored != null) {
                  final entry = _QueuedPerformanceOperation(
                    restored.record,
                    queueEntryId: restored.queueEntryId,
                    retentionPriority: _retentionPriority(
                      restored.record,
                      mustKeep: restored.record is PerformanceRecord
                          ? _mustKeepPerformance(
                              restored.record as PerformanceRecord,
                            )
                          : true,
                    ),
                  );
                  if (restoredIds.add(entry.queueEntryId)) {
                    _pendingOperations.addLast(entry);
                  }
                }
              }
            }
            final frames = decoded['frames'];
            if (frames is Map) {
              int? valid(String key) {
                final v = frames[key];
                return v is int && v >= 0 && v <= 1000000 ? v : null;
              }

              final total = valid('frame_count'),
                  slow = valid('slow_frame_count'),
                  build = valid('slow_build_count'),
                  raster = valid('slow_raster_count');
              if (total != null &&
                  slow != null &&
                  build != null &&
                  raster != null &&
                  slow <= total &&
                  math.max(build, raster) <= slow &&
                  slow <= build + raster) {
                final room = 1000000 - _frames.total;
                // Keep whole consistent groups; never independently clamp a
                // group into an impossible build/raster/slow relationship.
                if (total <= room) {
                  _frames.total += total;
                  _frames.slow += slow;
                  _frames.build += build;
                  _frames.raster += raster;
                }
              }
            }
            // No clear/read gap: durable pending evidence remains until a
            // successful upload's serialized trailing clear completes.
          } catch (_) {
            if (current()) {
              try {
                await restore.store.clear();
              } catch (_) {}
            }
          } finally {
            if (current()) {
              _restoring = false;
              _queueSpoolWrite();
            }
          }
        }
      } finally {
        _spoolRunning = false;
      }
    }());
  }
}
