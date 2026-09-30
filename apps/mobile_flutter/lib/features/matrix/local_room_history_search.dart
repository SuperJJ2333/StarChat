import 'dart:async';
import 'bounded_history_search.dart';
import 'chat_search_query_controller.dart';
import 'local_room_history_snapshot.dart';
import 'local_search_id_snapshot.dart';

/// Bounded device-local scan. SQLCipher pages never enter the rendered timeline
/// and never trigger SDK remote pagination. Each source retains one 512-row
/// page and one matching head; a k-way merge retains result ordering across
/// historical direct rooms without collecting all matching plaintext.
final class LocalRoomHistorySearch {
  LocalRoomHistorySearch(
      {required this.roomIds,
      required this.readPage,
      this.openIds,
      this.readByIds,
      this.onResult,
      required this.project,
      this.sourceRevision,
      LocalRoomHistorySnapshot? snapshot,
      this.pageSize = 512})
      : assert((openIds == null) == (readByIds == null)),
        snapshot = snapshot ??
            LocalRoomHistorySnapshot(
                roomIds: roomIds,
                readPage: readPage,
                sourceRevision: sourceRevision,
                pageSize: pageSize);
  final LocalRoomHistorySnapshot snapshot;
  final List<String> Function() roomIds;
  final Future<List<ChatSearchMessage>> Function(
      String roomId, int offset, int limit) readPage;
  final Future<LocalSearchIdSnapshot> Function(String roomId)? openIds;
  final Future<List<ChatSearchMessage>> Function(
      String roomId, List<String> eventIds)? readByIds;
  final void Function(String sourceRoomId, ChatSearchMessage row)? onResult;
  final ChatSearchMessage? Function(String roomId, ChatSearchMessage message)
      project;
  final int pageSize;
  final int Function()? sourceRevision;
  int? _sourceRevision;
  int _generation = 0, _page = 0;
  final _sources = <String, _LocalSourceCursor>{};
  final _seen = <String>{};
  bool _coverageIncomplete = false;

  void cancel() {
    _generation++;
    _page = 0;
    for (final source in _sources.values) {
      source.ids?.dispose();
    }
    _sources.clear();
    _seen.clear();
    _coverageIncomplete = false;
  }

  Future<ChatSearchSlice> search(ChatSearchFilters filters,
      {ChatSearchCursor? cursor, int limit = 50}) async {
    if (limit <= 0) return const ChatSearchSlice(items: [], nextCursor: null);
    if (cursor == null) {
      cancel();
      for (final roomId in roomIds().toSet()) {
        _sources[roomId] = _LocalSourceCursor();
      }
      _sourceRevision = sourceRevision?.call();
    } else if (cursor.eventId != 'local:$_generation' ||
        cursor.order != _page) {
      throw const HistorySearchCancelled();
    }
    final snapshotGeneration = snapshot.generation;
    if (cursor != null &&
        sourceRevision != null &&
        _sourceRevision != sourceRevision!()) {
      for (final source in _sources.values) {
        source.ids?.dispose();
      }
      _sources.clear();
      for (final roomId in roomIds().toSet()) {
        _sources[roomId] = _LocalSourceCursor();
      }
      _sourceRevision = sourceRevision!();
    }
    final generation = _generation;
    final revision = _sourceRevision;
    final beforeSources = {
      for (final entry in _sources.entries) entry.key: entry.value.copy()
    };
    final beforeCoverage = _coverageIncomplete;
    final added = <String>[], evicted = <String>[];
    void check() {
      if (generation != _generation ||
          snapshotGeneration != snapshot.generation ||
          (sourceRevision != null && revision != sourceRevision!())) {
        throw const HistorySearchCancelled();
      }
    }

    var visited = 0;
    var scannedPages = 0;
    final found = <ChatSearchMessage>[];
    final sliceClock = Stopwatch()..start();
    bool sliceFull() =>
        visited >= 1024 ||
        (visited > 0 &&
            sliceClock.elapsed >= const Duration(milliseconds: 100));
    Future<void> prepareHead(String roomId, _LocalSourceCursor state) async {
      while (state.head == null && !state.done) {
        check();
        if (sliceFull()) return;
        if (state.index >= state.buffer.length) {
          if (state.lastPage) {
            state.done = true;
            state.buffer = const [];
            break;
          }
          // A verified hit can be shown without waiting for another disk page.
          // Continue through the current page for dense results, then resume
          // the frozen scan on the next UI request.
          if (found.isNotEmpty) return;
          List<ChatSearchMessage> page;
          if (openIds == null) {
            page = await snapshot.page(roomId, state.offset, pageSize);
          } else {
            var ids = state.ids;
            if (ids == null) {
              ids = await openIds!(roomId);
              try {
                check();
              } catch (_) {
                ids.dispose();
                rethrow;
              }
              state.ids = ids;
            }
            final pageIds = await ids.page(state.offset, pageSize);
            check();
            // Search already owns one active page per source. Do not also fill
            // the shared 64 MiB calendar/history projection cache while
            // scanning many old or nonmatching messages.
            page = completeLocalHistoryPage(
                pageIds, await readByIds!(roomId, pageIds));
          }
          check();
          scannedPages++;
          state.offset += page.length;
          state.buffer = page;
          state.index = 0;
          state.lastPage = page.length < pageSize;
          if (page.isEmpty) {
            state.done = true;
            break;
          }
        }
        final raw = state.buffer[state.index++];
        check();
        _coverageIncomplete = _coverageIncomplete || raw.isUndecrypted;
        final item = project(roomId, raw);
        if (item != null &&
            !_seen.contains(item.eventId) &&
            filters.matches(item)) {
          state.head = item;
        }
        visited++;
        if (visited % 64 == 0) {
          await Future<void>.delayed(Duration.zero);
          check();
        }
      }
    }

    try {
      while (found.length < limit) {
        for (final entry in _sources.entries.toList(growable: false)) {
          await prepareHead(entry.key, entry.value);
        }
        check();
        // A source without a matching head may still contain a newer hit.
        // Defer the merge until every source has a head or is exhausted.
        if (_sources.values.any((s) => !s.done && s.head == null)) {
          if (found.isNotEmpty || sliceFull()) break;
          continue;
        }
        _LocalSourceCursor? best;
        String? bestRoomId;
        for (final entry in _sources.entries) {
          final source = entry.value;
          if (source.head == null) continue;
          if (best == null || _compare(source.head!, best.head!) < 0) {
            best = source;
            bestRoomId = entry.key;
          }
        }
        if (best == null) break;
        final item = best.head!;
        best.head = null;
        if (_seen.add(item.eventId)) {
          found.add(item);
          added.add(item.eventId);
          onResult?.call(bestRoomId!, item);
        }
        while (_seen.length > 60000) {
          final id = _seen.first;
          evicted.add(id);
          _seen.remove(id);
        }
      }
      check();
      _page++;
      return ChatSearchSlice(
          items: found,
          coverageIncomplete: _coverageIncomplete,
          scannedPages: scannedPages,
          scannedRows: visited,
          nextCursor: _sources.values.every((s) => s.done && s.head == null)
              ? null
              : ChatSearchCursor(order: _page, eventId: 'local:$_generation'));
    } catch (_) {
      if (generation == _generation) {
        for (final entry in _sources.entries) {
          final old = beforeSources[entry.key]?.ids;
          if (!identical(entry.value.ids, old)) entry.value.ids?.dispose();
        }
        _sources
          ..clear()
          ..addAll(beforeSources);
        _coverageIncomplete = beforeCoverage;
        _seen.removeAll(added);
        _seen.addAll(evicted);
        if (sourceRevision != null && revision != sourceRevision!()) {
          // Release stale copied plaintext immediately. The same continuation
          // cursor can retry the latest source, skipping already published IDs.
          for (final source in _sources.values) {
            source.ids?.dispose();
          }
          _sources.clear();
          for (final roomId in roomIds().toSet()) {
            _sources[roomId] = _LocalSourceCursor();
          }
          _sourceRevision = sourceRevision!();
        }
      }
      rethrow;
    }
  }
}

int _compare(ChatSearchMessage a, ChatSearchMessage b) {
  final time = b.timestamp.compareTo(a.timestamp);
  return time != 0 ? time : b.eventId.compareTo(a.eventId);
}

final class _LocalSourceCursor {
  int offset = 0, index = 0;
  bool lastPage = false, done = false;
  List<ChatSearchMessage> buffer = const [];
  ChatSearchMessage? head;
  LocalSearchIdSnapshot? ids;
  _LocalSourceCursor copy() => _LocalSourceCursor()
    ..offset = offset
    ..index = index
    ..lastPage = lastPage
    ..done = done
    ..buffer = buffer
    ..head = head
    ..ids = ids;
}
