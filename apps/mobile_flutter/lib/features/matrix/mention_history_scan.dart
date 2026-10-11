import 'dart:async';
import 'dart:collection';

import 'package:matrix/matrix.dart';

import '../../core/maintenance_activity.dart';
import 'unread_mention_tracker.dart';

/// The only strong body references owned by a scan. Release before the next
/// page; keeping this page object does not keep its consumed bodies alive.
final class MentionScanPage {
  MentionScanPage._(this.events, this.hasMore, this._release);
  final List<Event> events;
  final bool hasMore;
  final void Function() _release;
  bool _released = false;
  void release() {
    if (_released) return;
    _released = true;
    events.clear();
    _release();
  }
}

final class MentionScanCanceled implements Exception {
  const MentionScanCanceled();
}

/// Fixed head/read-boundary scan. IDs remain compatible with v2 mention
/// metadata; body memory is one page, independent of the unread interval.
/// Metadata compaction/migration is deliberately a separate operation.
final class MentionHistoryScan {
  MentionHistoryScan._(
      this.room, this.targetEventId, this._active, this._maintenance)
      : _generation = room.historyGeneration {
    _poll = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!_isActive) unawaited(close());
    });
  }

  static Future<MentionHistoryScan> open(Room room,
      {String? targetEventId,
      bool Function()? shouldContinue,
      MaintenanceActivity? maintenance}) async {
    final scan = MentionHistoryScan._(
        room,
        targetEventId,
        shouldContinue ?? () => true,
        maintenance ?? MaintenanceActivity.instance);
    try {
      await scan._discover();
      return scan;
    } catch (_) {
      await scan.close();
      rethrow;
    }
  }

  final Room room;
  final String? targetEventId;
  final bool Function() _active;
  final MaintenanceActivity _maintenance;
  final int _generation;
  final _cancelled = Completer<void>();
  final _readCancellations = <void Function()>{};
  final _ids = <String>[];
  TimelineIdSnapshot? _snapshot;
  MentionScanPage? _page;
  Timer? _poll;
  bool _closed = false, _reading = false;
  int _offset = 0;
  bool reachedTarget = false;
  bool exhausted = false;
  String? get headEventId {
    _check();
    return _ids.firstOrNull;
  }

  List<String> get eventIds => UnmodifiableListView(_ids);
  bool get complete => reachedTarget || exhausted;
  bool get _isActive =>
      !_closed && _active() && room.historyGeneration == _generation;

  void _check() {
    if (!_isActive) throw const MentionScanCanceled();
  }

  Future<T> _guard<T>(Future<T> operation) async {
    final result = Completer<T>();
    void cancel() {
      if (!result.isCompleted) {
        result.completeError(const MentionScanCanceled());
      }
    }

    _readCancellations.add(cancel);
    unawaited(operation.then<void>((value) {
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    }));
    try {
      final value = await result.future;
      _check();
      return value;
    } finally {
      // A Future.any listener on a long-lived cancellation future would retain
      // every completed payload result until the entire scan closes.
      _readCancellations.remove(cancel);
    }
  }

  Future<MaintenanceLease> _permit() async {
    _check();
    final lease = await _maintenance.acquireHeavy(
        cancelled: () => !_isActive, cancellation: _cancelled.future);
    if (lease == null) throw const MentionScanCanceled();
    try {
      _check();
      return lease;
    } catch (_) {
      lease.release();
      rethrow;
    }
  }

  Future<void> _afterRead(MaintenanceLease lease) async {
    await _maintenance.waitForIdle(cancelled: _cancelled.future, lease: lease);
    _check();
  }

  Future<void> _discover() async {
    final database = room.client.database;
    if (database == null) {
      throw StateError('Persisted mention history unavailable');
    }
    final seen = <String>{};
    while (!reachedTarget && !exhausted) {
      var lease = await _permit();
      try {
        if (_snapshot == null) {
          // An appended history fragment is anchored after the last captured
          // ID, so concurrent newer sync events cannot move this scan's head.
          final opening = database.openTimelineIdSnapshot(room,
              afterEventId: _ids.lastOrNull);
          unawaited(opening.then<void>((value) {
            if (!_isActive) value.dispose();
          }, onError: (Object _, StackTrace __) {}));
          _snapshot = await _guard(opening);
        }
        final page = await _guard(_snapshot!.next(limit: 256));
        for (final id in page.ids) {
          if (!seen.add(id)) continue;
          _ids.add(id);
          if (id == targetEventId) {
            reachedTarget = true;
            break;
          }
        }
        _snapshot!.accept(page);
        await _afterRead(lease);
        if (reachedTarget || page.hasMore) continue;
        _snapshot!.dispose();
        _snapshot = null;
        final before = room.prev_batch;
        if (before == null) {
          exhausted = true;
          continue;
        }
        // The public SDK request owns its network/sync transaction; it does not
        // consume this reader's local body budget. Do not hold the exclusive
        // maintenance permit through an arbitrarily long network response.
        lease.release();
        final received = await _guard(room.requestHistory(historyCount: 256));
        lease = await _permit();
        await _afterRead(lease);
        if (received == 0 && before == room.prev_batch) {
          // Lack of progress is not proof that an inaccessible boundary was
          // reached. Preserve the checkpoint and let a future scan retry.
          break;
        }
        if (received == 0 && room.prev_batch == null) exhausted = true;
      } finally {
        lease.release();
      }
    }
    _snapshot?.dispose();
    _snapshot = null;
  }

  Future<MentionScanPage> next({int limit = 256}) async {
    if (limit < 1 || limit > 256) throw RangeError.range(limit, 1, 256);
    _check();
    if (_reading) throw StateError('Mention page read already active');
    _reading = true;
    _page?.release();
    _page = null;
    MaintenanceLease? lease;
    final events = <Event>[];
    try {
      lease = await _permit();
      final end = (_offset + limit).clamp(0, _ids.length);
      for (var index = _offset; index < end; index++) {
        _check();
        final event = await _guard(room.getLocalEventById(_ids[index],
            shouldContinue: () => _isActive));
        if (event == null) throw StateError('Mention history body unavailable');
        events.add(event);
      }
      await _afterRead(lease);
      _offset = end;
      final held = lease;
      lease = null;
      return _page =
          MentionScanPage._(events, _offset < _ids.length, held.release);
    } catch (_) {
      events.clear();
      rethrow;
    } finally {
      lease?.release();
      _reading = false;
    }
  }

  /// Establish the fixed interval's ranks before classifying bodies, without
  /// registering an unbounded ID list in one UI-isolate turn. This preserves
  /// the v2 metadata schema and existing relative order after cancellation.
  Future<void> registerOrder(UnreadMentionTracker state) async {
    int? headOrder;
    for (var offset = 0;
        offset < _ids.length && headOrder == null;
        offset += 256) {
      final lease = await _permit();
      try {
        final end = (offset + 256).clamp(0, _ids.length);
        for (var index = offset; index < end; index++) {
          if (state.hasEventOrder(_ids[index])) {
            headOrder = state.orderFor(_ids[index]) + index;
            break;
          }
        }
        await _afterRead(lease);
      } finally {
        lease.release();
      }
    }
    headOrder ??= state.newestTimelineOrder + _ids.length;
    for (var offset = 0; offset < _ids.length; offset += 256) {
      final lease = await _permit();
      try {
        final end = (offset + 256).clamp(0, _ids.length);
        state.registerTimeline(_ids.sublist(offset, end),
            newestOrder: headOrder - offset);
        await _afterRead(lease);
      } finally {
        lease.release();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _poll?.cancel();
    if (!_cancelled.isCompleted) _cancelled.complete();
    for (final cancel in _readCancellations.toList()) {
      cancel();
    }
    _readCancellations.clear();
    _snapshot?.dispose();
    _snapshot = null;
    _page?.release();
    _page = null;
    _ids.clear();
  }
}
