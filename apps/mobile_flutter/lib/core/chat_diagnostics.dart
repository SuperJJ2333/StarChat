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
}

enum ChatDiagnosticError {
  slow,
  network,
  timeout,
  rejected,
  cancelled,
  incomplete,
  unknown
}

enum ChatDiagnosticPlatform { android, ios, other }

/// The transport must honor abort by closing its independent HTTP connection.
/// Its status is intentionally opaque to auth/session-refresh mechanisms.
typedef ChatDiagnosticUploader = Future<int> Function(
    ChatDiagnosticBatch batch, Future<void> abort);

final class ChatDiagnosticBatch {
  ChatDiagnosticBatch._(this.version, this.platform, List<_Event> events)
      : _events = List.unmodifiable(events.map((e) => e.copy()));
  final String version;
  final ChatDiagnosticPlatform platform;
  final List<_Event> _events;
  Map<String, Object?> toJson() => {
        'version': version,
        'platform': platform.name,
        'events': [for (final event in _events) event.toJson()],
      };
}

final class _Event {
  _Event(this.stage, this.error, this.status, this.elapsedMs, this.count,
      {String? operationId})
      : operationId = operationId ?? const Uuid().v4();
  final ChatDiagnosticStage stage;
  final ChatDiagnosticError error;
  final int? status;
  final String operationId;
  int elapsedMs;
  int count;
  (ChatDiagnosticStage, ChatDiagnosticError, int?) get key =>
      (stage, error, status);
  _Event copy() =>
      _Event(stage, error, status, elapsedMs, count, operationId: operationId);
  Map<String, Object?> toJson() => {
        'operation_id': operationId,
        'stage': stage.name,
        'error': error.name,
        'elapsed_ms': elapsedMs,
        'count': count,
        'status': status,
      };
}

/// In-memory only, closed metadata. Callers cannot submit text, IDs or stacks.
/// Recording is bounded O(1), never awaits, and never writes on the UI path.
final class ChatDiagnostics {
  ChatDiagnostics({DateTime Function()? now}) : _now = now ?? DateTime.now;
  static ChatDiagnostics instance = ChatDiagnostics();
  final DateTime Function() _now;
  final _pending = <(ChatDiagnosticStage, ChatDiagnosticError, int?), _Event>{};
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
      int? status}) {
    if (_upload == null ||
        (error == ChatDiagnosticError.slow && elapsed.inMilliseconds < 250)) {
      return;
    }
    final safeStatus =
        status != null && status >= 100 && status <= 599 ? status : null;
    final key = (stage, error, safeStatus);
    final existing = _pending[key];
    final ms = elapsed.inMilliseconds.clamp(0, 3600000);
    final safeCount = count.clamp(1, 1000000);
    if (existing != null) {
      existing.count = (existing.count + safeCount).clamp(1, 1000000);
      existing.elapsedMs = math.max(existing.elapsedMs, ms);
      return;
    }
    if (_pending.length >= 100) return;
    _pending[key] = _Event(stage, error, safeStatus, ms, safeCount);
  }

  /// Also bounded when explicitly requested: never bypasses cadence/backoff.
  Future<void> flush() async {
    final upload = _upload;
    final now = _now();
    if (upload == null ||
        _pending.isEmpty ||
        _inFlight ||
        (_nextAllowed != null && now.isBefore(_nextAllowed!))) {
      return;
    }
    _inFlight = true;
    final epoch = _epoch;
    final events = _pending.values.take(20).map((e) => e.copy()).toList();
    final batch = ChatDiagnosticBatch._(_version, _platform, events);
    final abort = Completer<void>();
    _abort = abort;
    _nextAllowed = now.add(const Duration(minutes: 1));
    final deadline = Timer(const Duration(seconds: 5), () {
      if (!abort.isCompleted) abort.complete();
    });
    var success = false;
    try {
      success = await upload(batch, abort.future) == 202;
    } catch (_) {
      // Never feed diagnostics transport errors back into diagnostics.
    } finally {
      deadline.cancel();
      _inFlight = false;
      if (identical(_abort, abort)) _abort = null;
    }
    if (epoch != _epoch) return;
    if (success) {
      _failures = 0;
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
