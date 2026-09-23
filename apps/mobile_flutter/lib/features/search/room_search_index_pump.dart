import 'dart:async';

import 'package:flutter/foundation.dart';

import '../matrix/room_timeline_controller.dart';

/// Local, rebuildable search maintenance. A sync notification only queues the
/// bounded viewport; projecting older history happens in event-loop slices.
/// Neither timers nor `async` move CPU work to another isolate: the item/time
/// budgets below bound each slice (one projection/callback may exceed 2 ms).
final class RoomSearchIndexPump {
  RoomSearchIndexPump({
    required this.source,
    required this.isActive,
    required this.upsert,
    required this.remove,
    this.batchSize = 64,
    this.maxTrackedIds = 60000,
    this.maxPendingIds = 2048,
  }) : assert(batchSize > 0 && maxTrackedIds > 0 && maxPendingIds > 0);

  /// Must replay the current authoritative loaded history, including updates
  /// queued through request. This is not a durable sink for arbitrary streams.
  /// Unloaded history continues to be recovered by the encrypted DB backfill.
  final Iterable<RoomMessageViewModel> Function() source;
  final bool Function() isActive;
  final void Function(List<RoomMessageViewModel>) upsert;
  final void Function(List<String>) remove;
  final int batchSize;
  final int maxTrackedIds;
  final int maxPendingIds;
  final _pending = <String, RoomMessageViewModel>{};
  final _known = <String, _SearchVersion>{};
  final _overrides = <String>{};
  Iterator<RoomMessageViewModel>? _history;
  List<RoomMessageViewModel> _retry = const [];
  Timer? _timer;
  bool _dirty = false;
  bool _disposed = false;
  bool _waitingForHistory = false;

  @visibleForTesting
  int get pendingCount => _pending.length;
  @visibleForTesting
  int get overrideCount => _overrides.length;

  void _rescanAfterOverflow() {
    _history = null;
    _overrides.clear();
    _retry = const [];
    _dirty = true;
  }

  void request(Iterable<RoomMessageViewModel> priority) {
    if (_disposed) return;
    if (!isActive()) {
      dispose();
      return;
    }
    for (final row in priority) {
      if (!_pending.containsKey(row.id) && _pending.length >= maxPendingIds) {
        // The source owns overflow, rather than retaining an unbounded second
        // history. Never continue an older iterator after dropping overrides.
        _rescanAfterOverflow();
        if (!row.isRecalled) continue;
        _pending.remove(_pending.keys.first); // Recall takes priority.
      }
      _pending[row.id] = row;
      if (_history != null) {
        if (!_overrides.contains(row.id) &&
            _overrides.length >= maxPendingIds + batchSize) {
          _rescanAfterOverflow();
        } else {
          _overrides.add(row.id);
        }
      }
    }
    _dirty = true;
    if (_waitingForHistory) {
      _timer?.cancel();
      _timer = null;
      _waitingForHistory = false;
    }
    _schedule(const Duration(milliseconds: 1));
  }

  void _schedule(Duration delay) {
    // Fixed deadline: sustained traffic must not keep cancelling pending work.
    _timer ??= Timer(delay, _drain);
  }

  void _drain() {
    _timer = null;
    _waitingForHistory = false;
    if (_disposed) return;
    if (!isActive()) {
      dispose();
      return;
    }
    final batch = <RoomMessageViewModel>[];
    final watch = Stopwatch()..start();
    try {
      if (_retry.isNotEmpty) {
        // Newer queued updates (especially recalls) supersede a failed write.
        batch.addAll(_retry.where((r) => !_pending.containsKey(r.id)));
        _retry = const [];
      }
      if (_history == null && _dirty) {
        _dirty = false;
        _history = source().iterator;
        _overrides
          ..clear()
          ..addAll(_pending.keys);
      }
      var work = batch.length;
      // Reserve history progress even when visible traffic never stops.
      final priorityLimit = (batchSize + 1) ~/ 2;
      var priorityWork = 0;
      while (_pending.isNotEmpty &&
          work < batchSize &&
          priorityWork < priorityLimit) {
        final id = _pending.keys.first;
        batch.add(_pending.remove(id)!);
        priorityWork++;
        work++;
        if (watch.elapsedMicroseconds >= 2000) break;
      }
      while (_history != null &&
          work < batchSize &&
          watch.elapsedMicroseconds < 2000) {
        if (!_history!.moveNext()) {
          _history = null;
          _overrides.clear();
          break;
        }
        work++;
        final row = _history!.current;
        if (!_overrides.contains(row.id)) batch.add(row);
      }
      final changed = <RoomMessageViewModel>[];
      final removed = <String>[];
      final versions = <String, _SearchVersion>{};
      // A restarted source is newer than failed writes. Last observation wins
      // per ID, so an old retry and a current recall cannot both be committed.
      for (final row in {for (final row in batch) row.id: row}.values) {
        final version = _version(row);
        if (_known[row.id] == version) continue;
        versions[row.id] = version;
        if (version.$5) {
          changed.add(row);
        } else {
          removed.add(row.id);
        }
      }
      if (removed.isNotEmpty) remove(removed);
      if (_disposed || !isActive()) {
        dispose();
        return;
      }
      if (changed.isNotEmpty) upsert(changed);
      if (_disposed || !isActive()) {
        dispose();
        return;
      }
      // Only acknowledge successfully applied data. Callbacks are idempotent.
      for (final entry in versions.entries) {
        _known.remove(entry.key);
        _known[entry.key] = entry.value;
      }
      while (_known.length > maxTrackedIds) {
        _known.remove(_known.keys.first);
      }
    } catch (_) {
      // No message content/error text is logged. Keep consumed rows for retry.
      _retry = batch;
      // Source creation/iteration can fail too. A failed iterator is not a
      // reliable continuation; retry from the current authoritative source.
      _history = null;
      _dirty = true;
      _schedule(const Duration(seconds: 1));
      return;
    }
    if (_pending.isNotEmpty || _history != null || _retry.isNotEmpty) {
      _schedule(const Duration(milliseconds: 4));
    } else if (_dirty) {
      _waitingForHistory = true;
      _schedule(const Duration(milliseconds: 100));
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _history = null;
    _retry = const [];
    _pending.clear();
    _known.clear();
    _overrides.clear();
  }
}

typedef _SearchVersion = (String, String, DateTime, bool, bool);
_SearchVersion _version(RoomMessageViewModel row) => (
      row.senderId,
      row.text,
      row.timestamp,
      row.isOwn,
      !row.isRecalled &&
          !row.isFlashPhoto &&
          !row.isSdkLocalEcho &&
          row.text.trim().isNotEmpty,
    );
