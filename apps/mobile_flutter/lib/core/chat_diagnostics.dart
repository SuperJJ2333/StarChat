import 'dart:async';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';

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
  ChatDiagnosticBatch._(
      this.version, this.platform, List<_Event> events, this._frames)
      : _events = List.unmodifiable(events.map((e) => e.copy()));
  final String version;
  final ChatDiagnosticPlatform platform;
  final List<_Event> _events;
  final _FrameCounts? _frames;
  Map<String, Object?> toJson() => {
        'version': version,
        'platform': platform.name,
        'events': [for (final event in _events) event.toJson()],
        if (_frames != null) 'frames': _frames!.toJson(),
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
  ChatDiagnostics({DateTime Function()? now}) : _now = now ?? DateTime.now;
  static ChatDiagnostics instance = ChatDiagnostics();
  final DateTime Function() _now;
  final _pending = <_EventKey, _Event>{};
  _FrameCounts _frames = _FrameCounts();
  bool _framesSupported = true;
  ChatDiagnosticUploader? _upload;
  String _version = '';
  ChatDiagnosticPlatform _platform = ChatDiagnosticPlatform.other;
  Timer? _timer;
  Completer<void>? _abort;
  bool _inFlight = false;
  int _epoch = 0;
  int _failures = 0;
  DateTime? _nextAllowed;
  int get pendingCount => _pending.length;

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
    _frames = _FrameCounts();
    _framesSupported = true;
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
    if (_pending.length >= 100) return;
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
  }

  /// Also bounded when explicitly requested: never bypasses cadence/backoff.
  Future<void> flush() async {
    final upload = _upload;
    final now = _now();
    if (upload == null ||
        (_pending.isEmpty && _frames.total == 0) ||
        _inFlight ||
        (_nextAllowed != null && now.isBefore(_nextAllowed!))) {
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final events = _pending.values.take(20).map((e) => e.copy()).toList();
    final frames = _frames.total > 0 ? _frames.copy() : null;
    final batch = ChatDiagnosticBatch._(_version, _platform, events, frames);
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
    if (status == 422 && frames != null) {
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
    } else {
      _failures = math.min(_failures + 1, 5);
      final delayMinutes = math.min(1 << (_failures - 1), 15);
      _nextAllowed = _now().add(Duration(minutes: delayMinutes));
    }
  }
}
