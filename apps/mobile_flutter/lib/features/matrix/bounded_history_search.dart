import 'dart:async';

import 'chat_search_query_controller.dart';

final class HistorySearchCancelled implements Exception {
  const HistorySearchCancelled();
}

/// A resumable scan of local, decrypted models. Work is bounded even when no
/// messages match; a continuation is independent of the last matching message.
final class BoundedHistorySearch<T> {
  BoundedHistorySearch({
    required this.snapshot,
    this.snapshotBefore,
    required this.eventId,
    required this.project,
    required this.exhausted,
    required this.loadEarlier,
    this.maxPages = 3,
    this.maxMessages = 600,
    this.budget = const Duration(seconds: 2),
  });

  final Iterable<T> Function() snapshot;

  /// An indexed, newest-first source can start immediately before the last
  /// scanned event after pagination. Legacy sources remain bounded by budget.
  final Iterable<T> Function(String? beforeEventId)? snapshotBefore;
  final String Function(T) eventId;
  final ChatSearchMessage? Function(T) project;
  final bool Function() exhausted;
  final Future<void> Function() loadEarlier;
  final int maxPages, maxMessages;
  final Duration budget;
  final Set<String> _seen = {};
  Iterator<T>? _pending;
  Future<void>? _loadFlight;
  bool _refreshOnResume = false;
  String? _lastScannedId;
  int _generation = 0, _page = 0;

  void cancel() {
    _generation++;
    _pending = null;
    _refreshOnResume = false;
    _lastScannedId = null;
    _seen.clear();
  }

  Future<ChatSearchSlice> search(ChatSearchFilters filters,
      {ChatSearchCursor? cursor, int limit = 50}) async {
    final clock = Stopwatch()..start();
    if (cursor == null) {
      cancel();
      _page = 0;
      _pending = _freshIterator();
    } else if (cursor.eventId != 'scan:$_generation' || cursor.order != _page) {
      throw const HistorySearchCancelled();
    }
    if (_refreshOnResume) {
      _pending = _freshIterator();
      _refreshOnResume = false;
    }
    final generation = _generation;
    void checkActive() {
      if (generation != _generation) throw const HistorySearchCancelled();
    }

    final found = <ChatSearchMessage>[];
    var pages = 0, visited = 0;
    var complete = false;
    while (found.length < limit &&
        visited < maxMessages &&
        clock.elapsed < budget) {
      checkActive();
      final pending = _pending;
      if (pending != null && pending.moveNext()) {
        final raw = pending.current;
        visited++;
        _lastScannedId = eventId(raw);
        if (_seen.add(_lastScannedId!)) {
          final item = project(raw);
          if (item != null && filters.matches(item)) found.add(item);
        }
        // Awaiting an already completed SDK future only yields microtasks.
        // Yield to the event queue so input, paint and cancellation can run.
        if (visited % 64 == 0) {
          await Future<void>.delayed(Duration.zero);
          checkActive();
        }
        continue;
      }
      _pending = null;
      if (exhausted()) {
        complete = true;
        break;
      }
      if (pages >= maxPages) break;
      pages++;
      final remaining = budget - clock.elapsed;
      if (remaining <= Duration.zero) break;
      final flight = _loadFlight ??= loadEarlier();
      try {
        await flight.timeout(remaining);
        if (identical(_loadFlight, flight)) _loadFlight = null;
      } on TimeoutException {
        // Keep the real in-flight operation: subsequent batches join it rather
        // than spawning parallel uncancellable SDK requests.
        _refreshOnResume = true;
        break;
      } finally {
        unawaited(flight.then<void>((_) {
          if (identical(_loadFlight, flight)) _loadFlight = null;
        }, onError: (Object _, StackTrace __) {
          if (identical(_loadFlight, flight)) _loadFlight = null;
        }));
      }
      checkActive();
      // Count and yield while traversing already-seen rows too: a sparse query
      // must not hide an unbounded synchronous scan inside Iterable.where.
      _pending = _freshIterator();
    }
    checkActive();
    _page++;
    return ChatSearchSlice(
        items: found,
        nextCursor: complete
            ? null
            : ChatSearchCursor(order: _page, eventId: 'scan:$_generation'));
  }

  Iterator<T> _freshIterator() =>
      (snapshotBefore?.call(_lastScannedId) ?? snapshot()).iterator;
}
