import 'dart:async';
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
  ChatDiagnosticSpoolStore? _spool;
  Future<String?>? _spoolScope;
  bool _spoolRunning = false;
  ({
    ChatDiagnosticSpoolStore store,
    Future<String?> scope,
    List<_Event> events,
    List<PerformanceRecord> operations,
    _FrameCounts frames,
    DateTime created,
    int epoch
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
      required ChatDiagnosticUploader upload,
      ChatDiagnosticSpoolStore? store,
      Future<String?> Function()? spoolScope}) {
    stopSession();
    if (!RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}(\+\d{1,8})?$').hasMatch(version)) {
      return;
    }
    _version = version;
    _platform = platform;
    _upload = upload;
    _spool = store;
    _spoolCreated = _now();
    if (store != null && spoolScope != null) {
      _spoolScope = Future.sync(spoolScope).then(
          (value) => value != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(value)
              ? value
              : null,
          onError: (Object _, StackTrace __) => null);
      _restoreSpool();
    }
    _nextAllowed = _now().add(const Duration(minutes: 1));
    _timer =
        Timer.periodic(const Duration(minutes: 1), (_) => unawaited(flush()));
  }

  void stopSession() {
    _spoolTimer?.cancel();
    _queueSpoolWrite();
    _spool = null;
    _spoolScope = null;
    _restoring = false;
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
    _networkStageSupported = true;
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
    _expirePending();
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
    _beginPendingRecord();
    _pendingOperations.addLast(record);
    _scheduleSpoolWrite();
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
      final processing = record.betweenMs(PerformanceStage.syncResponseReceived,
          PerformanceStage.syncProcessingDone);
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
      final processing = record.betweenMs(PerformanceStage.syncResponseReceived,
          PerformanceStage.syncProcessingDone);
      final cleanup = record.betweenMs(PerformanceStage.syncProcessingDone,
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
    if (upload == null ||
        (_pending.isEmpty &&
            _pendingOperations.isEmpty &&
            _frames.total == 0) ||
        _inFlight ||
        _restoring ||
        (_nextAllowed != null && now.isBefore(_nextAllowed!))) {
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final events = <_Event>[];
    final operations = <PerformanceRecord>[];
    final frameGroup = _frames;
    _FrameCounts? frames = frameGroup.total > 0 ? frameGroup.copy() : null;

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
      _pending.remove(event.key);
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
    if (status == 422 &&
        operations.isEmpty &&
        frames == null &&
        events.any(
            (event) => event.stage == ChatDiagnosticStage.networkRequest)) {
      // Only this newly introduced stage is incompatible. Preserve legacy
      // events for a later supported batch; never drop an entire mixed batch.
      _networkStageSupported = false;
      _pending.removeWhere(
          (key, _) => key.$1 == ChatDiagnosticStage.networkRequest);
    }
    if (success) {
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
    _queueSpoolWrite();
  }

  void _expirePending() {
    final created = _spoolCreated;
    if (created != null && _now().difference(created) > spoolExpiry) {
      _pending.clear();
      _pendingOperations.clear();
      _frames = _FrameCounts();
      _spoolCreated = null;
    }
  }

  void _beginPendingRecord() {
    _expirePending();
    if (_pending.isEmpty && _pendingOperations.isEmpty) _spoolCreated = _now();
  }

  // record() only creates one timer. Encoding, local I/O and bounded decoding
  // run on this deferred worker. At most one I/O and one trailing snapshot.
  void _scheduleSpoolWrite() {
    if (_spool == null || _spoolTimer?.isActive == true) return;
    _spoolTimer = Timer(const Duration(seconds: 1), _queueSpoolWrite);
  }

  void _queueSpoolWrite() {
    _spoolTimer?.cancel();
    final store = _spool;
    final scope = _spoolScope;
    if (store == null || scope == null) return;
    _spoolWrite = (
      store: store,
      scope: scope,
      events: [for (final e in _pending.values) e.copy()],
      operations: _pendingOperations.toList(growable: false),
      frames: _frames.copy(),
      created: _spoolCreated ?? _now(),
      epoch: _epoch
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
                      write.frames.total == 0 ||
                  _now().difference(write.created) > spoolExpiry) {
                await write.store.clear();
                continue;
              }
              final events = <Map<String, Object?>>[];
              final operations = <Map<String, Object?>>[];
              final body = <String, Object?>{
                'schema': 2,
                'scope': scope,
                'created_ms': write.created.millisecondsSinceEpoch,
                'events': events,
                'operations': operations,
                'frames': write.frames.toJson()
              };
              // Encode each candidate once, stopping at the oldest bounded
              // prefix. Whole-payload encoding then sees at most 64 KiB;
              // never re-encode 100 large operations while removing one tail.
              var bytes = utf8.encode(jsonEncode(body)).length;
              bool append(List<Map<String, Object?>> target,
                  Map<String, Object?> item) {
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
              for (final operation in write.operations) {
                if (!append(operations, {
                  ...operation.toJson(),
                  'frames_total': operation.frames.total,
                  if (operation.packetsLost != null)
                    'packets_lost': operation.packetsLost,
                  if (operation.packetsReceived != null)
                    'packets_received': operation.packetsReceived,
                })) {
                  break;
                }
              }
              final payload = jsonEncode(body);
              await write.store.write(payload);
            } catch (_) {/* Metadata storage must never fail business work. */}
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
                decoded['schema'] != 2 ||
                decoded['scope'] != scope ||
                decoded['created_ms'] is! int) {
              await restore.store.clear();
              continue;
            }
            final created = DateTime.fromMillisecondsSinceEpoch(
                decoded['created_ms'] as int);
            final age = _now().difference(created);
            if (age.isNegative || age > spoolExpiry) {
              await restore.store.clear();
              continue;
            }
            _spoolCreated = created;
            final events = decoded['events'];
            if (events is List) {
              for (final item in events.take(100)) {
                if (pendingCount >= 100) break;
                if (item is! Map ||
                    item.keys.any((key) => !const {
                          'operation_id',
                          'stage',
                          'error',
                          'elapsed_ms',
                          'count',
                          'status',
                          'retry_count',
                          'lifecycle'
                        }.contains(key))) {
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
                    !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
                        .hasMatch(id)) {
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
                    lifecycle: lifecycle);
                final existing = _pending[e.key];
                if (existing == null) {
                  _pending[e.key] = e;
                } else {
                  existing.count = (existing.count + e.count).clamp(1, 1000000);
                  existing.elapsedMs =
                      math.max(existing.elapsedMs, e.elapsedMs);
                }
              }
            }
            final operations = decoded['operations'];
            if (operations is List) {
              for (final rawOperation in operations.take(100)) {
                if (pendingCount >= 100) break;
                final operation = restoreDiagnosticOperation(rawOperation);
                if (operation != null &&
                    !_pendingOperations
                        .any((e) => e.operationId == operation.operationId)) {
                  _pendingOperations.addLast(operation);
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
