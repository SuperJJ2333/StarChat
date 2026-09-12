import 'dart:async';

import 'package:flutter/foundation.dart';

enum MatrixOutgoingWorkState {
  queued,
  preparing,
  ready,
  sending,
  sent,
  failed,
  canceled
}

enum MatrixOutgoingTargetState { pending, sent, failed, partial, canceled }

/// Immutable route-independent metadata for a pending outgoing bubble.
enum MatrixOutgoingPresentationKind { text, image, video, voice, file }

final class MatrixOutgoingWorkPresentation {
  MatrixOutgoingWorkPresentation({
    required this.kind,
    required this.text,
    required this.createdAt,
    this.mimeType,
    this.filename,
    this.voiceDuration,
  });

  final MatrixOutgoingPresentationKind kind;
  final String text;
  final DateTime createdAt;
  final String? mimeType;
  final String? filename;
  final Duration? voiceDuration;
}

final class MatrixOutgoingWorkCapacityException implements Exception {
  const MatrixOutgoingWorkCapacityException();
  @override
  String toString() => '同时后台发送任务过多，请等待当前任务完成后重试';
}

final class MatrixOutgoingFileTooLargeException implements Exception {
  const MatrixOutgoingFileTooLargeException();
  @override
  String toString() => '文件大小不能超过100MB';
}

final class MatrixOutgoingWorkAttempt {
  MatrixOutgoingWorkAttempt._(
      {required this.accountId,
      required this.txid,
      required bool Function() isActive})
      : _isActive = isActive;
  final String accountId;
  final String txid;
  final bool Function() _isActive;
  void ensureActive() {
    if (!_isActive()) throw StateError('MATRIX_OUTGOING_WORK_REVOKED');
  }
}

/// Immutable identifiers from one SDK timeline echo.
final class MatrixOutgoingWorkEcho {
  const MatrixOutgoingWorkEcho({
    this.roomId,
    this.eventId,
    this.transactionId,
  });

  final String? roomId;
  final String? eventId;
  final String? transactionId;
}

/// A retained immutable media/source snapshot shared by every target in a job.
/// The caller owns it until admission succeeds. Once admitted, this coordinator
/// releases it only after all targets are sent or canceled; failed targets keep
/// it for a retry. This is in-process only, so process death drops the work.
final class MatrixOutgoingWorkSource {
  MatrixOutgoingWorkSource({
    required this.id,
    required this.retainedBytes,
    this.preparationBytes = 0,
    Future<void> Function(MatrixOutgoingWorkAttempt attempt)? prepare,
    Future<void> Function()? release,
  })  : _prepare = prepare,
        _release = release,
        _prepared = prepare == null,
        assert(retainedBytes >= 0),
        assert(preparationBytes >= 0);

  final String id;

  /// Bytes already held by the caller at admission. They count immediately.
  final int retainedBytes;

  /// A bounded claim made just before a deferred source starts preparation.
  /// Asset/library handles are cheap to admit, while their compressed output is
  /// still constrained by the same owner-wide ceiling during preparation and
  /// through retries.
  final int preparationBytes;
  Future<void> Function(MatrixOutgoingWorkAttempt attempt)? _prepare;
  Future<void> Function()? _release;
  bool _prepared;
  bool _released = false;
  bool _preparationReserved = false;

  bool get isPrepared => _prepared;
  bool get hasPreparationReservation => _preparationReserved;
  int get retainedBudgetBytes =>
      retainedBytes + (_preparationReserved ? preparationBytes : 0);

  void _reservePreparation() {
    _preparationReserved = true;
  }

  Future<void> _prepareWith(MatrixOutgoingWorkAttempt attempt) async {
    if (_prepared) return;
    await _prepare?.call(attempt);
    attempt.ensureActive();
    _prepared = true;
  }

  /// Also used by an admission caller to clean up a source which was rejected.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    final release = _release;
    _prepare = null;
    _release = null;
    try {
      await release?.call();
    } catch (_) {
      // Cleanup errors do not turn a terminal/canceled delivery back into work.
    }
  }
}

/// One independently retryable item. New media callers use the job [source].
/// The legacy prepare/release hooks keep metadata-only callers source-safe while
/// migration completes; each becomes a zero-byte per-item source internally.
final class MatrixOutgoingWorkItem {
  MatrixOutgoingWorkItem({
    required this.id,
    required this.targetRoomId,
    required this.txid,
    Future<void> Function(MatrixOutgoingWorkAttempt attempt)? prepare,
    required Future<String> Function(MatrixOutgoingWorkAttempt attempt) send,
    Future<void> Function()? release,
    MatrixOutgoingWorkPresentation? presentation,
  })  : _legacyPrepare = prepare,
        _send = send,
        _legacyRelease = release,
        presentation = presentation ??
            MatrixOutgoingWorkPresentation(
              kind: MatrixOutgoingPresentationKind.text,
              text: '',
              createdAt: DateTime.now(),
            );

  final String id;
  final String targetRoomId;
  final String txid;
  Future<void> Function(MatrixOutgoingWorkAttempt attempt)? _legacyPrepare;
  Future<String> Function(MatrixOutgoingWorkAttempt attempt)? _send;
  Future<void> Function()? _legacyRelease;
  MatrixOutgoingWorkState _state = MatrixOutgoingWorkState.queued;
  MatrixOutgoingWorkSource? _legacySource;

  MatrixOutgoingWorkState get state => _state;
  final MatrixOutgoingWorkPresentation presentation;
  String? _eventId;
  String? get eventId => _eventId;
  bool _echoed = false;

  MatrixOutgoingWorkSource? _sourceFor(MatrixOutgoingWorkJob job) {
    if (job.source != null) return job.source;
    if (_legacyPrepare == null && _legacyRelease == null) return null;
    return _legacySource ??= MatrixOutgoingWorkSource(
      id: 'legacy:$id',
      retainedBytes: 0,
      prepare: _legacyPrepare,
      release: _legacyRelease,
    );
  }

  Future<String> _sendWith(MatrixOutgoingWorkAttempt attempt) =>
      _send!(attempt);
  void _releaseSendClosure() {
    _send = null;
    _legacyPrepare = null;
    _legacyRelease = null;
  }
}

final class MatrixOutgoingWorkJob {
  MatrixOutgoingWorkJob(
      {required this.id,
      required List<MatrixOutgoingWorkItem> items,
      this.source,
      DateTime? createdAt})
      : items = List.unmodifiable(items),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final List<MatrixOutgoingWorkItem> items;
  final MatrixOutgoingWorkSource? source;
  final DateTime createdAt;
  bool _preparing = false;

  MatrixOutgoingTargetState targetState(String roomId) {
    final targetItems =
        items.where((item) => item.targetRoomId == roomId).toList();
    if (targetItems.isEmpty) {
      throw ArgumentError.value(roomId, 'roomId', 'is not a job destination');
    }
    final states = targetItems.map((item) => item.state).toSet();
    if (states.length == 1 && states.single == MatrixOutgoingWorkState.sent) {
      return MatrixOutgoingTargetState.sent;
    }
    if (states.length == 1 &&
        states.single == MatrixOutgoingWorkState.canceled) {
      return MatrixOutgoingTargetState.canceled;
    }
    final hasSent = states.contains(MatrixOutgoingWorkState.sent);
    final hasFailed = states.contains(MatrixOutgoingWorkState.failed);
    if (hasSent && (hasFailed || states.length > 1)) {
      return MatrixOutgoingTargetState.partial;
    }
    if (hasFailed && states.length == 1) {
      return MatrixOutgoingTargetState.failed;
    }
    return MatrixOutgoingTargetState.pending;
  }
}

/// Bounded account-owned work. It survives route changes during one Matrix
/// session but is not a durable OS-background outbox.
final class MatrixOutgoingWorkCoordinator extends ChangeNotifier {
  MatrixOutgoingWorkCoordinator({
    required this.accountId,
    this.maxConcurrentTransfers = 3,
    this.maxOutstandingItems = 128,
    this.maxReadySources = 1,
    this.maxRetainedSourceBytes = 128 * 1024 * 1024,
    this.maxRetainedTerminalJobs = 64,
  })  : assert(maxConcurrentTransfers > 0),
        assert(maxOutstandingItems > 0),
        assert(maxReadySources > 0),
        assert(maxRetainedSourceBytes >= 0),
        assert(maxRetainedTerminalJobs > 0);

  final String accountId;
  final int maxConcurrentTransfers;
  final int maxOutstandingItems;
  final int maxReadySources;
  final int maxRetainedSourceBytes;
  final int maxRetainedTerminalJobs;
  final Map<String, MatrixOutgoingWorkJob> _jobs = {};
  final Set<MatrixOutgoingWorkSource> _ownedSources = {};
  bool _active = true;
  bool _disposed = false;
  int _epoch = 0;
  int _activePreparation = 0;
  int _activeTransfers = 0;
  int _activeReleases = 0;
  int _retainedSourceBytes = 0;
  Completer<void>? _progress;
  final Map<String, Set<String>> _earlyEchoEventIdsByRoom = {};
  int _earlyEchoEventCount = 0;

  bool get isActive => _active;
  int get retainedSourceBytes => _retainedSourceBytes;

  /// Prepared payloads waiting for a transfer. Active uploads do not count,
  /// allowing up to [maxConcurrentTransfers] useful sends plus bounded waiting.
  int get readySourceCount => _jobs.values.where(_isReadySource).length;

  MatrixOutgoingWorkJob? job(String id) => _jobs[id];

  List<MatrixOutgoingWorkItem> itemsForRoom(String roomId) =>
      List.unmodifiable([
        for (final job in _jobs.values)
          for (final item in job.items)
            if (item.targetRoomId == roomId &&
                item.state != MatrixOutgoingWorkState.canceled &&
                !(item.state == MatrixOutgoingWorkState.sent && item._echoed))
              item,
      ]);

  /// Confirms that an SDK timeline row has replaced a successful local ack.
  /// Some SDK echoes omit transaction ids, so the authoritative event id is
  /// also accepted for de-duplication.
  void acknowledgeEcho({String? eventId, String? transactionId}) =>
      acknowledgeEchoes([
        MatrixOutgoingWorkEcho(
          eventId: eventId,
          transactionId: transactionId,
        ),
      ]);

  /// Marks several SDK echoes in one pass through the in-memory work items.
  /// Callers should pre-filter timeline history to the pending transaction or
  /// event identifiers before using this method.
  void acknowledgeEchoes(Iterable<MatrixOutgoingWorkEcho> echoes) {
    final received = [
      for (final echo in echoes)
        if ((echo.eventId?.isNotEmpty ?? false) ||
            (echo.transactionId?.isNotEmpty ?? false))
          echo,
    ];
    if (received.isEmpty) return;
    final byRoomTransaction = <(String, String), MatrixOutgoingWorkItem>{};
    final byRoomEvent = <(String, String), MatrixOutgoingWorkItem>{};
    final byTransaction = <String, MatrixOutgoingWorkItem>{};
    final byEvent = <String, MatrixOutgoingWorkItem>{};
    final sendingRooms = <String>{};
    for (final item in _allItems()) {
      if (item._state == MatrixOutgoingWorkState.canceled) continue;
      byRoomTransaction[(item.targetRoomId, item.txid)] = item;
      byTransaction[item.txid] = item;
      final eventId = item._eventId;
      if (eventId != null) {
        byRoomEvent[(item.targetRoomId, eventId)] = item;
        byEvent[eventId] = item;
      }
      if (item._state == MatrixOutgoingWorkState.sending && eventId == null) {
        sendingRooms.add(item.targetRoomId);
      }
    }
    var changed = false;
    for (final echo in received) {
      final roomId = echo.roomId;
      final eventId = echo.eventId;
      final transactionId = echo.transactionId;
      MatrixOutgoingWorkItem? item;
      if (roomId != null) {
        if (transactionId != null) {
          item = byRoomTransaction[(roomId, transactionId)];
        }
        // Matrix can give an event its definitive id before the local
        // transaction id is visible. Keep the room boundary, but fall back
        // to that authoritative id when both identifiers are supplied.
        if (item == null && eventId != null) {
          item = byRoomEvent[(roomId, eventId)];
        }
      } else {
        if (transactionId != null) item = byTransaction[transactionId];
        if (item == null && eventId != null) item = byEvent[eventId];
      }
      if (item == null) {
        if (roomId != null &&
            transactionId == null &&
            eventId != null &&
            sendingRooms.contains(roomId)) {
          _rememberEarlyEchoEvent(roomId, eventId);
        }
        continue;
      }
      if (eventId != null && transactionId != null) item._eventId = eventId;
      if (!item._echoed) {
        item._echoed = true;
        changed = true;
      }
      switch (item._state) {
        case MatrixOutgoingWorkState.queued:
        case MatrixOutgoingWorkState.ready:
        case MatrixOutgoingWorkState.failed:
          item._state = MatrixOutgoingWorkState.sent;
          changed = true;
        case MatrixOutgoingWorkState.preparing:
        case MatrixOutgoingWorkState.sending:
        case MatrixOutgoingWorkState.sent:
        case MatrixOutgoingWorkState.canceled:
          break;
      }
    }
    if (changed) {
      for (final job in _jobs.values) {
        for (final item in job.items) {
          if (item._state == MatrixOutgoingWorkState.sent) {
            _releaseLegacyItemIfTerminal(item);
          }
        }
        _releaseSourceIfTerminal(job);
      }
      _trimTerminalJobs();
      _schedule();
      _notifyListeners();
      _signalProgress();
    }
  }

  void _rememberEarlyEchoEvent(String roomId, String eventId) {
    final roomEvents = _earlyEchoEventIdsByRoom.putIfAbsent(roomId, () => {});
    if (!roomEvents.add(eventId)) return;
    _earlyEchoEventCount++;
    while (_earlyEchoEventCount > maxOutstandingItems) {
      final oldestRoom = _earlyEchoEventIdsByRoom.keys.first;
      final oldestEvents = _earlyEchoEventIdsByRoom[oldestRoom]!;
      oldestEvents.remove(oldestEvents.first);
      _earlyEchoEventCount--;
      if (oldestEvents.isEmpty) _earlyEchoEventIdsByRoom.remove(oldestRoom);
    }
  }

  bool _consumeEarlyEchoEvent(String roomId, String eventId) {
    final roomEvents = _earlyEchoEventIdsByRoom[roomId];
    if (roomEvents == null || !roomEvents.remove(eventId)) return false;
    _earlyEchoEventCount--;
    if (roomEvents.isEmpty) _earlyEchoEventIdsByRoom.remove(roomId);
    return true;
  }

  /// Returns after local admission; never waits for preparation, upload or SDK acknowledgement.
  Future<MatrixOutgoingWorkJob> enqueue(
    MatrixOutgoingWorkJob incoming, {
    void Function()? onAccepted,
  }) async {
    if (!_active) throw StateError('MATRIX_OUTGOING_WORK_REVOKED');
    final existing = _jobs[incoming.id];
    if (existing != null) return existing;
    _validate(incoming);
    final source = incoming.source;
    if (_outstandingItemCount + incoming.items.length > maxOutstandingItems ||
        _retainedSourceBytes + (incoming.source?.retainedBytes ?? 0) >
            maxRetainedSourceBytes ||
        (source != null &&
            source.retainedBytes + source.preparationBytes >
                maxRetainedSourceBytes)) {
      throw const MatrixOutgoingWorkCapacityException();
    }
    if (incoming.source != null && !_ownedSources.add(incoming.source!)) {
      throw ArgumentError('A source may be admitted by only one outgoing job');
    }
    try {
      onAccepted?.call();
    } catch (_) {
      if (incoming.source != null) _ownedSources.remove(incoming.source);
      rethrow;
    }
    _retainedSourceBytes += incoming.source?.retainedBytes ?? 0;
    _jobs[incoming.id] = incoming;
    _schedule();
    _notifyListeners();
    _signalProgress();
    return incoming;
  }

  /// Atomically admits a frozen multi-message forwarding batch. Validation and
  /// capacity checks happen before any source becomes coordinator-owned.
  Future<List<MatrixOutgoingWorkJob>> enqueueBatch(
    List<MatrixOutgoingWorkJob> incoming, {
    void Function()? onAccepted,
  }) async {
    if (!_active) throw StateError('MATRIX_OUTGOING_WORK_REVOKED');
    if (incoming.isEmpty) return const [];
    final ids = <String>{};
    final sources = <MatrixOutgoingWorkSource>{};
    var itemCount = 0;
    var sourceBytes = 0;
    for (final job in incoming) {
      if (_jobs.containsKey(job.id) || !ids.add(job.id)) {
        throw ArgumentError('Outgoing batch job ids must be new and unique');
      }
      _validate(job);
      itemCount += job.items.length;
      final source = job.source;
      if (source != null) {
        if (!sources.add(source) || _ownedSources.contains(source)) {
          throw ArgumentError(
              'A source may be admitted by only one outgoing job');
        }
        if (source.retainedBytes + source.preparationBytes >
            maxRetainedSourceBytes) {
          throw const MatrixOutgoingWorkCapacityException();
        }
        sourceBytes += source.retainedBytes;
      }
    }
    if (_outstandingItemCount + itemCount > maxOutstandingItems ||
        _retainedSourceBytes + sourceBytes > maxRetainedSourceBytes) {
      throw const MatrixOutgoingWorkCapacityException();
    }
    onAccepted?.call();
    for (final job in incoming) {
      final source = job.source;
      if (source != null) _ownedSources.add(source);
      _retainedSourceBytes += source?.retainedBytes ?? 0;
      _jobs[job.id] = job;
    }
    _schedule();
    _notifyListeners();
    _signalProgress();
    return List.unmodifiable(incoming);
  }

  Future<void> retryFailed(String jobId) async {
    if (!_active) throw StateError('MATRIX_OUTGOING_WORK_REVOKED');
    final job = _jobs[jobId];
    if (job == null) throw ArgumentError.value(jobId, 'jobId', 'not found');
    for (final item in job.items) {
      if (item._state == MatrixOutgoingWorkState.failed) {
        item._state = MatrixOutgoingWorkState.queued;
      }
    }
    _schedule();
    _notifyListeners();
    _signalProgress();
  }

  Future<void> retryItem(String jobId, String itemId) async {
    if (!_active) throw StateError('MATRIX_OUTGOING_WORK_REVOKED');
    final job = _jobs[jobId];
    final item =
        job?.items.where((candidate) => candidate.id == itemId).firstOrNull;
    if (item == null) throw ArgumentError.value(itemId, 'itemId', 'not found');
    if (item._state == MatrixOutgoingWorkState.failed) {
      item._state = MatrixOutgoingWorkState.queued;
      _schedule();
      _notifyListeners();
      _signalProgress();
    }
  }

  Future<bool> retryTransaction(String transactionId) async {
    for (final entry in _jobs.entries) {
      for (final item in entry.value.items) {
        if (item.txid == transactionId &&
            item._state == MatrixOutgoingWorkState.failed) {
          await retryItem(entry.key, item.id);
          return true;
        }
      }
    }
    return false;
  }

  void cancelItem(String jobId, String itemId) {
    final job = _jobs[jobId];
    final item =
        job?.items.where((candidate) => candidate.id == itemId).firstOrNull;
    if (item == null) throw ArgumentError.value(itemId, 'itemId', 'not found');
    switch (item._state) {
      case MatrixOutgoingWorkState.queued:
      case MatrixOutgoingWorkState.ready:
      case MatrixOutgoingWorkState.failed:
        item._state = MatrixOutgoingWorkState.canceled;
        if (job!.source == null) _releaseLegacyItemIfTerminal(item);
        _releaseSourceIfTerminal(job);
      case MatrixOutgoingWorkState.preparing:
      case MatrixOutgoingWorkState.sending:
      case MatrixOutgoingWorkState.sent:
      case MatrixOutgoingWorkState.canceled:
        break;
    }
    _notifyListeners();
    _signalProgress();
  }

  /// Stops future work for this account epoch. A request already passed to an
  /// SDK/HTTP client cannot be recalled, but its result cannot mutate this epoch.
  void revoke(String reason) {
    if (!_active) return;
    _active = false;
    _epoch++;
    for (final job in _jobs.values) {
      for (final item in job.items) {
        switch (item._state) {
          case MatrixOutgoingWorkState.queued:
          case MatrixOutgoingWorkState.ready:
          case MatrixOutgoingWorkState.failed:
            item._state = MatrixOutgoingWorkState.canceled;
          case MatrixOutgoingWorkState.preparing:
          case MatrixOutgoingWorkState.sending:
          case MatrixOutgoingWorkState.sent:
          case MatrixOutgoingWorkState.canceled:
            break;
        }
        if (job.source == null) _releaseLegacyItemIfTerminal(item);
      }
      _releaseSourceIfTerminal(job);
    }
    _notifyListeners();
    _signalProgress();
  }

  Future<void> drain() async {
    while (_hasOutstandingWork) {
      final next = _progress ??= Completer<void>();
      await next.future;
    }
  }

  void _validate(MatrixOutgoingWorkJob job) {
    if (job.id.isEmpty || job.items.isEmpty || job.source?.id.isEmpty == true) {
      throw ArgumentError(
          'Outgoing work requires an id, items, and valid source');
    }
    final ids = <String>{};
    final txids = <String>{};
    for (final item in job.items) {
      if (item.id.isEmpty ||
          item.targetRoomId.isEmpty ||
          item.txid.isEmpty ||
          !ids.add(item.id) ||
          !txids.add(item.txid)) {
        throw ArgumentError(
            'Outgoing work item ids and txids must be non-empty and unique');
      }
    }
  }

  Iterable<MatrixOutgoingWorkItem> _allItems() sync* {
    for (final job in _jobs.values) {
      yield* job.items;
    }
  }

  bool get _hasOutstandingWork =>
      _activePreparation > 0 ||
      _activeTransfers > 0 ||
      _activeReleases > 0 ||
      _allItems().any((item) =>
          item._state == MatrixOutgoingWorkState.queued ||
          item._state == MatrixOutgoingWorkState.preparing ||
          item._state == MatrixOutgoingWorkState.ready ||
          item._state == MatrixOutgoingWorkState.sending);

  int get _outstandingItemCount => _allItems()
      .where((item) =>
          (item._state != MatrixOutgoingWorkState.sent || !item._echoed) &&
          item._state != MatrixOutgoingWorkState.canceled)
      .length;

  void _schedule() {
    if (!_active) return;
    _markReadyItems();
    _startPreparationIfAllowed();
    while (_activeTransfers < maxConcurrentTransfers) {
      final next = _allItems()
          .where((item) => item._state == MatrixOutgoingWorkState.ready)
          .firstOrNull;
      if (next == null) break;
      final job = _jobFor(next)!;
      next._state = MatrixOutgoingWorkState.sending;
      _activeTransfers++;
      unawaited(_runTransfer(job, next));
    }
    // Dispatching a ready source removes it from the waiting-payload budget.
    // Admit the next source only after that transition has been recorded.
    _startPreparationIfAllowed();
  }

  void _startPreparationIfAllowed() {
    while (_activePreparation == 0 && readySourceCount < maxReadySources) {
      final job = _nextUnpreparedJob();
      if (job != null) {
        final source = _sourceForJob(job)!;
        if (!_reservePreparationIfAllowed(source)) return;
        job._preparing = true;
        for (final item in job.items) {
          if (item._state == MatrixOutgoingWorkState.queued) {
            item._state = MatrixOutgoingWorkState.preparing;
          }
        }
        _activePreparation++;
        unawaited(_runPreparation(job, source));
        continue;
      }
      final legacy = _nextLegacyPreparation();
      if (legacy == null) return;
      final (legacyJob, legacyItem, legacySource) = legacy;
      legacyItem._state = MatrixOutgoingWorkState.preparing;
      _activePreparation++;
      unawaited(_runLegacyPreparation(legacyJob, legacyItem, legacySource));
    }
  }

  MatrixOutgoingWorkJob? _nextUnpreparedJob() {
    for (final job in _jobs.values) {
      if (job.source == null) continue;
      if (job._preparing) continue;
      final source = job.source;
      if (source != null &&
          !source.isPrepared &&
          _canReservePreparation(source) &&
          job.items
              .any((item) => item._state == MatrixOutgoingWorkState.queued)) {
        return job;
      }
    }
    return null;
  }

  bool _canReservePreparation(MatrixOutgoingWorkSource source) =>
      source.hasPreparationReservation ||
      _retainedSourceBytes + source.preparationBytes <= maxRetainedSourceBytes;

  bool _reservePreparationIfAllowed(MatrixOutgoingWorkSource source) {
    if (source.hasPreparationReservation) return true;
    if (!_canReservePreparation(source)) return false;
    source._reservePreparation();
    _retainedSourceBytes += source.preparationBytes;
    return true;
  }

  (MatrixOutgoingWorkJob, MatrixOutgoingWorkItem, MatrixOutgoingWorkSource)?
      _nextLegacyPreparation() {
    for (final job in _jobs.values) {
      if (job.source != null) continue;
      for (final item in job.items) {
        final source = item._sourceFor(job);
        if (item._state == MatrixOutgoingWorkState.queued &&
            source != null &&
            !source.isPrepared) {
          return (job, item, source);
        }
      }
    }
    return null;
  }

  void _markReadyItems() {
    for (final job in _jobs.values) {
      final source = _sourceForJob(job);
      if (job._preparing || (source != null && !source.isPrepared)) continue;
      for (final item in job.items) {
        final legacySource = job.source == null ? item._sourceFor(job) : null;
        if (item._state == MatrixOutgoingWorkState.queued &&
            (legacySource == null || legacySource.isPrepared)) {
          item._state = MatrixOutgoingWorkState.ready;
        }
      }
    }
  }

  MatrixOutgoingWorkSource? _sourceForJob(MatrixOutgoingWorkJob job) {
    return job.source;
  }

  MatrixOutgoingWorkJob? _jobFor(MatrixOutgoingWorkItem item) {
    for (final job in _jobs.values) {
      if (job.items.contains(item)) return job;
    }
    return null;
  }

  bool _isReadySource(MatrixOutgoingWorkJob job) {
    final source = _sourceForJob(job);
    return source != null &&
        source.isPrepared &&
        job.items.any((item) => item._state == MatrixOutgoingWorkState.ready) &&
        !job.items
            .any((item) => item._state == MatrixOutgoingWorkState.sending);
  }

  MatrixOutgoingWorkAttempt _attemptFor(MatrixOutgoingWorkItem item) {
    final epoch = _epoch;
    return MatrixOutgoingWorkAttempt._(
        accountId: accountId,
        txid: item.txid,
        isActive: () => _active && epoch == _epoch);
  }

  Future<void> _runPreparation(
      MatrixOutgoingWorkJob job, MatrixOutgoingWorkSource source) async {
    final attempt = _attemptFor(job.items.first);
    try {
      attempt.ensureActive();
      await source._prepareWith(attempt);
      attempt.ensureActive();
      for (final item in job.items) {
        if (item._state == MatrixOutgoingWorkState.preparing) {
          item._state = item._echoed
              ? MatrixOutgoingWorkState.sent
              : MatrixOutgoingWorkState.queued;
        }
      }
      _releaseSourceIfTerminal(job);
    } catch (_) {
      final state = attempt._isActive()
          ? MatrixOutgoingWorkState.failed
          : MatrixOutgoingWorkState.canceled;
      for (final item in job.items) {
        if (item._state == MatrixOutgoingWorkState.preparing) {
          // A stored SDK echo is authoritative even if the local preparation
          // future later fails or is cancelled.
          item._state = item._echoed ? MatrixOutgoingWorkState.sent : state;
        }
      }
      _releaseSourceIfTerminal(job);
    } finally {
      job._preparing = false;
      _activePreparation--;
      _schedule();
      _notifyListeners();
      _signalProgress();
    }
  }

  Future<void> _runLegacyPreparation(MatrixOutgoingWorkJob job,
      MatrixOutgoingWorkItem item, MatrixOutgoingWorkSource source) async {
    final attempt = _attemptFor(item);
    try {
      attempt.ensureActive();
      await source._prepareWith(attempt);
      attempt.ensureActive();
      if (item._state == MatrixOutgoingWorkState.preparing) {
        item._state = item._echoed
            ? MatrixOutgoingWorkState.sent
            : MatrixOutgoingWorkState.queued;
      }
      _releaseLegacyItemIfTerminal(item);
    } catch (_) {
      item._state = item._echoed
          ? MatrixOutgoingWorkState.sent
          : attempt._isActive()
              ? MatrixOutgoingWorkState.failed
              : MatrixOutgoingWorkState.canceled;
      _releaseLegacyItemIfTerminal(item);
    } finally {
      _activePreparation--;
      _schedule();
      _notifyListeners();
      _signalProgress();
    }
  }

  Future<void> _runTransfer(
      MatrixOutgoingWorkJob job, MatrixOutgoingWorkItem item) async {
    final attempt = _attemptFor(item);
    try {
      attempt.ensureActive();
      final eventId = await item._sendWith(attempt);
      attempt.ensureActive();
      if (eventId.isEmpty) throw StateError('Matrix event was not accepted');
      item._eventId ??= eventId;
      item._state = MatrixOutgoingWorkState.sent;
      if (_consumeEarlyEchoEvent(item.targetRoomId, eventId)) {
        item._echoed = true;
      }
    } catch (_) {
      item._state = !attempt._isActive()
          ? MatrixOutgoingWorkState.canceled
          : item._echoed
              ? MatrixOutgoingWorkState.sent
              : MatrixOutgoingWorkState.failed;
    } finally {
      _activeTransfers--;
      if (job.source == null) _releaseLegacyItemIfTerminal(item);
      _releaseSourceIfTerminal(job);
      _trimTerminalJobs();
      _schedule();
      _notifyListeners();
      _signalProgress();
    }
  }

  void _releaseSourceIfTerminal(MatrixOutgoingWorkJob job) {
    if (!job.items.every((item) =>
        item._state == MatrixOutgoingWorkState.sent ||
        item._state == MatrixOutgoingWorkState.canceled)) {
      return;
    }
    final source = _sourceForJob(job);
    for (final item in job.items) {
      item._releaseSendClosure();
    }
    if (source == null || !_ownedSources.remove(source)) return;
    _retainedSourceBytes -= source.retainedBudgetBytes;
    _activeReleases++;
    unawaited(source.release().whenComplete(() {
      _activeReleases--;
      _trimTerminalJobs();
      _notifyListeners();
      _signalProgress();
    }));
  }

  void _releaseLegacyItemIfTerminal(MatrixOutgoingWorkItem item) {
    if (item._state != MatrixOutgoingWorkState.sent &&
        item._state != MatrixOutgoingWorkState.canceled) {
      return;
    }
    final source = item._legacySource;
    if (source == null) return;
    item._legacySource = null;
    item._releaseSendClosure();
    _activeReleases++;
    unawaited(source.release().whenComplete(() {
      _activeReleases--;
      _trimTerminalJobs();
      _notifyListeners();
      _signalProgress();
    }));
  }

  void _signalProgress() {
    final pending = _progress;
    _progress = null;
    pending?.complete();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  void _trimTerminalJobs() {
    final terminal = <String>[
      for (final entry in _jobs.entries)
        if (entry.value.items.every((item) =>
            item._state == MatrixOutgoingWorkState.canceled ||
            (item._state == MatrixOutgoingWorkState.sent && item._echoed)))
          entry.key
    ];
    final excess = terminal.length - maxRetainedTerminalJobs;
    if (excess <= 0) return;
    for (final id in terminal.take(excess)) {
      _jobs.remove(id);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    revoke('dispose');
    super.dispose();
  }
}
