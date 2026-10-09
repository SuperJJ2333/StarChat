import 'dart:async';
import 'dart:typed_data';
import '../../core/performance_trace.dart';

import 'incremental_timeline_merge.dart';

import 'matrix_room_timeline_adapter.dart';
import 'room_history_date_capability.dart';
import 'room_event_context_capability.dart';
import 'room_timeline_controller.dart';
import 'room_timeline_viewport.dart';
import 'room_paged_history_source.dart';

final class _HistoryFrontier {
  _HistoryFrontier(this.source, this.anchor);
  final RoomPagedHistorySource source;
  final String? anchor;
  RoomHistoryReadCursor? cursor;
  RoomMessageViewModel? head;
  bool opened = false, exhausted = false;
}

final class _LogicalHistoryCursor implements RoomHistoryReadCursor {
  _LogicalHistoryCursor(
      this.owner, this.direction, this.frontiers, this.cutoff, this.generation);
  final LogicalConversationTimelineCapability owner;
  final RoomHistoryDirection direction;
  final Map<String, _HistoryFrontier> frontiers;
  final DateTime? cutoff;
  final int generation;
  bool disposed = false, reading = false;
  bool gap = false;
  @override
  void dispose() {
    if (disposed) return;
    disposed = true;
    for (final frontier in frontiers.values) {
      frontier.cursor?.dispose();
    }
    frontiers.clear();
    owner._historyReaders.remove(this);
  }
}

/// Receipts are bounded by events actually displayed by the conversation UI.
abstract interface class RoomVisibleReadCapability {
  Future<void> markReadVisible(Iterable<String> eventIds);
}

/// Routes event operations without exposing SDK rooms across the lease boundary.
abstract interface class RoomEventSourceCapability {
  String? sourceRoomId(String eventId);
}

/// One logical conversation, with a single authoritative outgoing room and
/// retained read-only history sources. Event IDs, never bodies, define identity.
final class LogicalConversationTimelineCapability
    implements
        RoomTimelineCapability,
        RoomRetryDiagnostics,
        RoomHistoryStatus,
        RoomFutureHistoryStatus,
        RoomMessageLookupSource,
        RoomVisibleReadCapability,
        RoomEventSourceCapability,
        RoomWindowedTimelineSource,
        RoomNewestFirstTimelineSource,
        RoomHistoryDateCapability,
        RoomEventContextCapability,
        RoomPagedHistorySource,
        RoomPresentationRevisionSource {
  LogicalConversationTimelineCapability({
    required this.primaryRoomId,
    required RoomTimelineCapability primary,
    required Map<String, RoomTimelineCapability> sources,
    void Function()? onDispose,
  })  : _sources = {
          primaryRoomId: primary,
          for (final entry in sources.entries)
            if (entry.key != primaryRoomId) entry.key: entry.value
        },
        _onDispose = onDispose;

  final String primaryRoomId;
  final Map<String, RoomTimelineCapability> _sources;
  final void Function()? _onDispose;
  final Map<String, String> _eventSources = {};
  final Map<String, String> _sourceHints = {};
  final _historyReaders = <_LogicalHistoryCursor>{};
  int _historyGeneration = 0;
  int _windowRevision = 0;
  List<Object>? _sourceRevisions;
  int _sourceRevision = 0;
  Object? _publishedStamp;
  List<RoomMessageViewModel> _publishedRows = const [];
  @override
  Object get presentationRevision {
    final revisions = <Object>[
      for (final source in _sources.values)
        source is RoomPresentationRevisionSource
            ? (source as RoomPresentationRevisionSource).presentationRevision
            : Object(),
    ];
    final previous = _sourceRevisions;
    if (previous == null ||
        previous.length != revisions.length ||
        Iterable<int>.generate(revisions.length)
            .any((i) => previous[i] != revisions[i])) {
      _sourceRevisions = revisions;
      _sourceRevision++;
    }
    return (_sourceRevision, _windowRevision);
  }

  @override
  bool get supportsPagedHistory => _sources.values.every((source) =>
      source is RoomPagedHistorySource &&
      (source as RoomPagedHistorySource).supportsPagedHistory);

  @override
  Future<RoomHistoryMessagePage> readHistoryPage({
    RoomHistoryReadCursor? cursor,
    String? anchorEventId,
    String? sourceRoomId,
    required RoomHistoryDirection direction,
    int rawLimit = 64,
    Future<void> Function()? beforeRead,
  }) async {
    _checkActive();
    if (rawLimit < 1 || rawLimit > 256) {
      throw RangeError.range(rawLimit, 1, 256);
    }
    if (!supportsPagedHistory) {
      throw UnsupportedError('History paging unavailable');
    }
    _LogicalHistoryCursor current;
    if (cursor == null) {
      final anchorRoom = sourceRoomId ??
          (anchorEventId == null ? null : this.sourceRoomId(anchorEventId)) ??
          primaryRoomId;
      if (!_sources.containsKey(anchorRoom)) {
        throw ArgumentError('Unknown history source');
      }
      DateTime? cutoff;
      if (anchorEventId != null &&
          sourceRoomId == null &&
          _sources.length > 1) {
        final anchorSource = _sources[anchorRoom]!;
        if (anchorSource is RoomMessageLookupSource) {
          cutoff = (await (anchorSource as RoomMessageLookupSource)
                  .lookupMessage(anchorEventId))
              ?.timestamp;
          _checkActive();
        }
      }
      current = _LogicalHistoryCursor(
          this,
          direction,
          {
            for (final entry in _sources.entries)
              if (sourceRoomId == null || entry.key == sourceRoomId)
                entry.key: _HistoryFrontier(
                    entry.value as RoomPagedHistorySource,
                    entry.key == anchorRoom ? anchorEventId : null),
          },
          cutoff,
          ++_historyGeneration);
      _historyReaders.add(current);
    } else {
      if (cursor is! _LogicalHistoryCursor ||
          !identical(cursor.owner, this) ||
          cursor.direction != direction ||
          cursor.disposed ||
          cursor.reading) {
        throw StateError('Invalid logical history cursor');
      }
      current = cursor;
    }
    current.reading = true;
    var rawWork = 0;
    final messages = <RoomMessageViewModel>[];
    final ownership = <String, String>{};
    try {
      while (messages.length < rawLimit) {
        var allReady = true;
        for (final entry in current.frontiers.entries) {
          final frontier = entry.value;
          if (frontier.head != null || frontier.exhausted) continue;
          if (rawWork >= rawLimit) {
            allReady = false;
            break;
          }
          await beforeRead?.call();
          final page = await frontier.source.readHistoryPage(
              cursor: frontier.cursor,
              anchorEventId: frontier.opened ? null : frontier.anchor,
              direction: direction,
              beforeRead: beforeRead,
              rawLimit: 1);
          try {
            await beforeRead?.call();
          } catch (_) {
            page.nextCursor?.dispose();
            rethrow;
          }
          if (_disposed || current.disposed) {
            page.nextCursor?.dispose();
            throw StateError('Logical history cursor disposed');
          }
          frontier.opened = true;
          if (!identical(frontier.cursor, page.nextCursor)) {
            frontier.cursor?.dispose();
          }
          frontier.cursor = page.nextCursor;
          rawWork += page.rawCount;
          frontier.exhausted = page.exhausted || page.gap;
          current.gap = current.gap || page.gap;
          if (!frontier.exhausted && frontier.cursor == null) {
            throw StateError('History continuation missing');
          }
          final candidate = page.messages.firstOrNull;
          final cutoff = current.cutoff;
          if (candidate != null &&
              (cutoff == null ||
                  frontier.anchor != null ||
                  (direction == RoomHistoryDirection.older
                      ? !candidate.timestamp.isAfter(cutoff)
                      : candidate.timestamp.isAfter(cutoff)))) {
            frontier.head = candidate;
          }
          if (frontier.head == null && !frontier.exhausted) allReady = false;
        }
        if (!allReady) break; // Filtered pages advance without moving the UI.
        MapEntry<String, _HistoryFrontier>? best;
        for (final entry in current.frontiers.entries) {
          final candidate = entry.value.head;
          if (candidate == null) continue;
          if (best == null) {
            best = entry;
            continue;
          }
          final other = best.value.head!;
          var comparison = candidate.timestamp.compareTo(other.timestamp);
          if (comparison == 0) comparison = candidate.id.compareTo(other.id);
          if (direction == RoomHistoryDirection.older
              ? comparison > 0
              : comparison < 0) {
            best = entry;
          }
        }
        if (best == null) break;
        final message = best.value.head!;
        best.value.head = null;
        if (!ownership.containsKey(message.id)) {
          messages.add(message);
          ownership[message.id] = best.key;
          hintSource(message.id, best.key);
        }
      }
      final exhausted =
          current.frontiers.values.every((f) => f.exhausted && f.head == null);
      final result = RoomHistoryMessagePage(
          messages: messages,
          exhausted: exhausted,
          nextCursor: exhausted ? null : current,
          gap: current.gap,
          fragmentGeneration: current.generation,
          rawCount: rawWork,
          sourceRoomIds: ownership);
      if (exhausted) current.dispose();
      return result;
    } catch (_) {
      if (cursor == null) current.dispose();
      rethrow;
    } finally {
      current.reading = false;
    }
  }

  bool _sourceIndexReady = false;
  final _merger = IncrementalTimelineMerge<RoomMessageViewModel>(
    idOf: (event) => event.id,
    compare: (a, b) {
      final order = a.timestamp.compareTo(b.timestamp);
      return order != 0 ? order : a.id.compareTo(b.id);
    },
  );
  bool _disposed = false;
  int _dateGeneration = 0, _monthGeneration = 0, _eventGeneration = 0;
  Completer<void>? _dateCancellation, _monthCancellation;
  static const _queryBudget = Duration(seconds: 13);
  RoomTimelineCapability get _primary => _sources[primaryRoomId]!;

  @override
  bool get supportsEventContext => _sources.values.any((source) =>
      source is RoomEventContextCapability &&
      (source as RoomEventContextCapability).supportsEventContext);

  @override
  void cancelPendingEventLookup() {
    _eventGeneration++;
    for (final source
        in _sources.values.whereType<RoomEventContextCapability>()) {
      source.cancelPendingEventLookup();
    }
  }

  @override
  Future<bool> locateEvent(String eventId) async {
    _checkActive();
    cancelPendingEventLookup();
    final generation = _eventGeneration;
    final roomId = sourceRoomId(eventId) ?? primaryRoomId;
    final source = _sources[roomId];
    if (source is! RoomEventContextCapability ||
        !(source as RoomEventContextCapability).supportsEventContext) {
      return false;
    }
    final found =
        await (source as RoomEventContextCapability).locateEvent(eventId);
    if (_disposed || generation != _eventGeneration || !found) return false;
    _eventSources[eventId] = roomId;
    snapshot();
    return selectAnchor(eventId) || !_windowEnabled;
  }

  bool _windowEnabled = false;
  RoomTimelineViewport<RoomMessageViewModel>? _mergedWindow;
  RoomWindowedTimelineSource? get _singleWindow => _windowEnabled &&
          _sources.length == 1 &&
          _primary is RoomWindowedTimelineSource
      ? _primary as RoomWindowedTimelineSource
      : null;

  @override
  void enableWindow() {
    _windowRevision++;
    _windowEnabled = true;
    for (final source
        in _sources.values.whereType<RoomWindowedTimelineSource>()) {
      source.enableWindow();
    }
    if (_singleWindow == null) {
      _mergedWindow =
          RoomTimelineViewport(idOf: (m) => m.id, project: (m) => m);
    }
  }

  @override
  void setHiddenFilter(bool Function(String, DateTime?)? hidden) {
    _windowRevision++;
    for (final source
        in _sources.values.whereType<RoomWindowedTimelineSource>()) {
      source.setHiddenFilter(hidden);
    }
  }

  @override
  bool get hasEarlierWindow =>
      _singleWindow?.hasEarlierWindow ?? _mergedWindow?.hasEarlier ?? false;
  @override
  bool get hasLaterWindow =>
      _singleWindow?.hasLaterWindow ?? _mergedWindow?.hasLater ?? false;
  @override
  int get totalMessages =>
      _singleWindow?.totalMessages ??
      _mergedWindow?.total ??
      _mergedSnapshot().length;
  @override
  Iterable<RoomMessageViewModel> get allMessages =>
      _singleWindow?.allMessages ?? _mergedWindow?.all ?? _mergedSnapshot();
  @override
  RoomMessageViewModel? findMessage(String id) =>
      _singleWindow?.findMessage(id) ?? _mergedWindow?.find(id);
  @override
  RoomMessageViewModel? get newestMessage =>
      _singleWindow?.newestMessage ?? _mergedWindow?.newest;
  @override
  DateTime? previousTimestamp(String id) =>
      _singleWindow?.previousTimestamp(id) ??
      _mergedWindow?.previousTimestamp(id);
  @override
  bool selectAnchor(String id) {
    _windowRevision++;
    return _singleWindow?.selectAnchor(id) ??
        _mergedWindow?.anchor(id) ??
        false;
  }

  @override
  void selectEarlier({String? retainEventId}) {
    _windowRevision++;
    if (_singleWindow != null) {
      _singleWindow!.selectEarlier(retainEventId: retainEventId);
    } else {
      _mergedWindow?.earlier(retainEventId: retainEventId);
    }
  }

  @override
  void selectLater({String? retainEventId}) {
    _windowRevision++;
    if (_singleWindow != null) {
      _singleWindow!.selectLater(retainEventId: retainEventId);
    } else {
      _mergedWindow?.later(retainEventId: retainEventId);
    }
  }

  @override
  void pinWindow() {
    _windowRevision++;
    _singleWindow?.pinWindow();
    _mergedWindow?.pin();
  }

  @override
  Iterable<RoomMessageViewModel> get newestFirstMessages =>
      historyNewestFirst();
  @override
  Iterable<RoomMessageViewModel> historyNewestFirst({String? beforeEventId}) =>
      _singleWindow != null && _primary is RoomNewestFirstTimelineSource
          ? (_primary as RoomNewestFirstTimelineSource)
              .historyNewestFirst(beforeEventId: beforeEventId)
          : _mergedWindow?.historyNewestFirst(beforeEventId: beforeEventId) ??
              _mergedSnapshot().reversed;

  /// Ownership transfers only on success; callers dispose rejected sources.
  void addSource(String roomId, RoomTimelineCapability source) {
    _checkActive();
    if (_sources.containsKey(roomId)) {
      if (identical(_sources[roomId], source)) return;
      throw StateError('Conversation source already attached');
    }
    _sources[roomId] = source;
    if (_windowEnabled) {
      if (source is RoomWindowedTimelineSource) {
        (source as RoomWindowedTimelineSource).enableWindow();
      }
      _mergedWindow ??=
          RoomTimelineViewport(idOf: (m) => m.id, project: (m) => m);
    }
    _sourceIndexReady = false;
    cancelPendingDateLookup();
    cancelMonthLookup();
  }

  /// A persisted room/event anchor can route a cold lookup directly to its room.
  void hintSource(String eventId, String roomId) {
    _checkActive();
    if (!_sources.containsKey(roomId)) throw StateError('Unknown source room');
    final known = _eventSources[eventId];
    if (known != null && known != roomId) {
      throw StateError('Conflicting event source');
    }
    _eventSources[eventId] = roomId;
    _sourceHints.remove(eventId);
    _sourceHints[eventId] = roomId;
    while (_sourceHints.length > 256) {
      final oldest = _sourceHints.keys.first;
      _sourceHints.remove(oldest);
      _eventSources.remove(oldest);
    }
  }

  void _checkActive() {
    if (_disposed) throw StateError('Conversation timeline is disposed');
  }

  @override
  List<RoomMessageViewModel> snapshot() {
    _checkActive();
    final stamp = presentationRevision;
    if (_publishedStamp == stamp) return _publishedRows;
    if (_singleWindow != null) {
      final rows = _primary.snapshot();
      _eventSources
        ..clear()
        ..addAll(_sourceHints);
      for (final row in rows) {
        _eventSources[row.id] = primaryRoomId;
      }
      _sourceIndexReady = true;
      _publishedStamp = stamp;
      return _publishedRows = rows;
    }
    final rows = _mergedSnapshot();
    final window = _mergedWindow;
    if (window == null) {
      _publishedStamp = stamp;
      return _publishedRows = rows;
    }
    window.update(rows);
    _publishedStamp = stamp;
    return _publishedRows = window.snapshot();
  }

  List<RoomMessageViewModel> _mergedSnapshot() {
    _checkActive();
    _eventSources
      ..clear()
      ..addAll(_sourceHints);
    final events = <String, RoomMessageViewModel>{};
    for (final entry in _sources.entries) {
      if (_windowEnabled && entry.value is RoomWindowedTimelineSource) {
        entry.value
            .snapshot(); // Refresh authoritative references before merging.
      }
      for (final event
          in _windowEnabled && entry.value is RoomWindowedTimelineSource
              ? (entry.value as RoomWindowedTimelineSource).allMessages
              : entry.value.snapshot()) {
        if (events.containsKey(event.id)) continue;
        events[event.id] = event;
        _eventSources[event.id] = entry.key;
      }
    }
    _sourceIndexReady = true;
    return _merger.update(events.values);
  }

  @override
  String? sourceRoomId(String eventId) {
    _checkActive();
    if (_singleWindow?.findMessage(eventId) != null) return primaryRoomId;
    // A cold caller gets one index build. Once a snapshot has been projected,
    // resolving every row for search/attachments must be O(1), including misses.
    // Sync/pagination refresh snapshots; a newly attached source invalidates the
    // index. Retain ownership of off-window events and explicit cold hints.
    if (!_sourceIndexReady) snapshot();
    return _eventSources[eventId];
  }

  Future<RoomTimelineCapability> _source(String eventId) async {
    var roomId = sourceRoomId(eventId);
    if (roomId == null) {
      await lookupMessage(eventId);
      roomId = _eventSources[eventId];
    }
    _checkActive();
    if (roomId == null) throw StateError('Unknown event source');
    return _sources[roomId]!;
  }

  @override
  Future<String> sendText(String text) {
    _checkActive();
    return _primary.sendText(text);
  }

  @override
  Future<String> sendTextWithTransaction(String text, String transactionId) {
    _checkActive();
    return _primary.sendTextWithTransaction(text, transactionId);
  }

  @override
  Future<String> sendTransferReference(
      String transferId, String amount, String? note,
      {String? receiverId, String? receiverMatrixId}) {
    _checkActive();
    return _primary.sendTransferReference(transferId, amount, note,
        receiverId: receiverId, receiverMatrixId: receiverMatrixId);
  }

  @override
  Future<String> sendRedPacketReference(String packetId, String greeting,
      {String? mode, String? recipientId, String? recipientMatrixId}) {
    _checkActive();
    return _primary.sendRedPacketReference(packetId, greeting,
        mode: mode,
        recipientId: recipientId,
        recipientMatrixId: recipientMatrixId);
  }

  @override
  Future<Uint8List> loadAttachment(String eventId) async =>
      (await _source(eventId)).loadAttachment(eventId);
  @override
  Future<Uint8List?> loadThumbnail(String eventId) async =>
      (await _source(eventId)).loadThumbnail(eventId);

  @override
  Future<void> retry(String transactionId) => _retry(transactionId);

  @override
  Future<void> retryWithDiagnostics(
          String transactionId, PerformanceTrace Function() startSdkAttempt) =>
      _retry(transactionId, startSdkAttempt: startSdkAttempt);

  Future<void> _retry(String transactionId,
      {PerformanceTrace Function()? startSdkAttempt}) async {
    _checkActive();
    final owners = <String>{};
    for (final entry in _sources.entries) {
      if (entry.value.snapshot().any((event) =>
          event.transactionId == transactionId || event.id == transactionId)) {
        owners.add(entry.key);
      }
    }
    if (owners.length != 1 || owners.single != primaryRoomId) {
      throw StateError(
          'Retry requires an unambiguous primary-room transaction');
    }
    final primary = _primary;
    if (startSdkAttempt != null && primary is RoomRetryDiagnostics) {
      await (primary as RoomRetryDiagnostics)
          .retryWithDiagnostics(transactionId, startSdkAttempt);
    } else {
      await primary.retry(transactionId);
    }
  }

  @override
  bool get canLoadHistory =>
      !_disposed &&
      _sources.values.any((source) =>
          source is! RoomHistoryStatus ||
          (source as RoomHistoryStatus).canLoadHistory);
  @override
  Future<void> loadHistory() async {
    _checkActive();
    // Future.wait waits for all sources and propagates failure; a failed source
    // must never be presented as exhausted merely because another source loaded.
    await Future.wait(_sources.values
        .where((source) =>
            source is! RoomHistoryStatus ||
            (source as RoomHistoryStatus).canLoadHistory)
        .map((source) => source.loadHistory()));
    _checkActive();
  }

  @override
  bool get hasFutureHistory =>
      !_disposed &&
      _sources.values.any((source) =>
          source is RoomFutureHistoryStatus &&
          (source as RoomFutureHistoryStatus).hasFutureHistory);
  @override
  Future<void> loadFutureHistory() async {
    _checkActive();
    await Future.wait(_sources.values
        .whereType<RoomFutureHistoryStatus>()
        .where((source) => source.hasFutureHistory)
        .map((source) => source.loadFutureHistory()));
    _checkActive();
  }

  @override
  bool get supportsMessageLookup => _sources.values.every((source) =>
      source is RoomMessageLookupSource &&
      (source as RoomMessageLookupSource).supportsMessageLookup);
  @override
  Future<RoomMessageViewModel?> lookupMessage(String eventId) async {
    _checkActive();
    final loaded = snapshot().where((event) => event.id == eventId).firstOrNull;
    if (loaded != null) return loaded;
    final knownRoom = _eventSources[eventId];
    final candidates = knownRoom == null
        ? _sources.entries
        : _sources.entries.where((entry) => entry.key == knownRoom);
    Object? failure;
    StackTrace? failureStack;
    for (final entry in candidates.toList()) {
      _checkActive();
      final source = entry.value;
      if (source is! RoomMessageLookupSource ||
          !(source as RoomMessageLookupSource).supportsMessageLookup) {
        failure ??=
            const ReplyMessageLookupUnavailable('Source lookup unsupported');
        continue;
      }
      try {
        final event =
            await (source as RoomMessageLookupSource).lookupMessage(eventId);
        _checkActive();
        if (event != null) {
          _eventSources[event.id] = entry.key;
          return event;
        }
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
      }
    }
    _checkActive();
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
    }
    return null;
  }

  /// Opening a composite timeline alone is not evidence that its history was read.
  @override
  Future<void> markRead() async {
    _checkActive();
  }

  @override
  Future<void> markReadVisible(Iterable<String> eventIds) async {
    _checkActive();
    snapshot();
    final visible = <String, Set<String>>{};
    for (final id in eventIds) {
      final roomId = _eventSources[id];
      if (roomId != null) (visible[roomId] ??= {}).add(id);
    }
    for (final entry in visible.entries) {
      _checkActive();
      final source = _sources[entry.key]!;
      if (source is RoomVisibleReadCapability) {
        await (source as RoomVisibleReadCapability)
            .markReadVisible(entry.value);
      } else {
        final messages = source.snapshot();
        final isContext = source is RoomHistoryDateCapability &&
            (source as RoomHistoryDateCapability).isViewingHistoryContext;
        final hasFuture = source is RoomFutureHistoryStatus &&
            (source as RoomFutureHistoryStatus).hasFutureHistory;
        if (!isContext &&
            !hasFuture &&
            messages.isNotEmpty &&
            entry.value.contains(messages.last.id)) {
          await source.markRead();
        }
      }
    }
  }

  Iterable<RoomHistoryDateCapability> get _dates =>
      _sources.values.whereType<RoomHistoryDateCapability>();

  @override
  Iterable<RoomHistoryDayMetadata> get loadedDayMetadata =>
      _dates.expand((source) => source.loadedDayMetadata);
  @override
  bool get isViewingHistoryContext =>
      _dates.any((source) => source.isViewingHistoryContext);
  @override
  CalendarMonth? get earliestMonth {
    final dates = _dates.toList();
    // An unknown lower bound in any source must not hide older history.
    if (dates.length != _sources.length ||
        dates.any((source) => source.earliestMonth == null)) {
      return null;
    }
    final months = dates.map((source) => source.earliestMonth!).toList()
      ..sort();
    return months.firstOrNull;
  }

  @override
  Future<RoomHistoryDayLocation?> locateDay(DateTime localDay) async {
    _checkActive();
    if (_dateCancellation != null) {
      cancelPendingDateLookup();
    } else {
      _dateGeneration++;
    }
    final generation = _dateGeneration;
    final cancellation = _dateCancellation = Completer<void>();
    try {
      return await Future.any<RoomHistoryDayLocation?>([
        _locateDay(localDay, generation),
        cancellation.future.then<RoomHistoryDayLocation?>(
            (_) => throw const RoomHistoryLookupCancelled()),
      ]).timeout(_queryBudget, onTimeout: () {
        if (generation == _dateGeneration) cancelPendingDateLookup();
        throw const RoomHistoryLookupIncomplete();
      });
    } finally {
      if (identical(_dateCancellation, cancellation)) _dateCancellation = null;
    }
  }

  Future<RoomHistoryDayLocation?> _locateDay(
      DateTime localDay, int generation) async {
    RoomHistoryDayLocation? selected;
    Object? failure;
    StackTrace? failureStack;
    for (final entry in _sources.entries.toList()) {
      if (_disposed || generation != _dateGeneration) {
        throw const RoomHistoryLookupCancelled();
      }
      if (entry.value is! RoomHistoryDateCapability) {
        failure ??= const RoomHistoryLookupIncomplete();
        continue;
      }
      try {
        final location = await (entry.value as RoomHistoryDateCapability)
            .locateDay(localDay);
        if (_disposed || generation != _dateGeneration) {
          throw const RoomHistoryLookupCancelled();
        }
        if (location != null) {
          _eventSources[location.eventId] = entry.key;
          if (selected == null || location.day.isBefore(selected.day)) {
            selected = location;
          }
        }
      } catch (error, stack) {
        if (error is RoomHistoryLookupCancelled) rethrow;
        failure ??= error;
        failureStack ??= stack;
      }
    }
    if (_disposed || generation != _dateGeneration) {
      throw const RoomHistoryLookupCancelled();
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
    }
    return selected;
  }

  @override
  void cancelPendingDateLookup() {
    _dateGeneration++;
    _dateCancellation?.complete();
    _dateCancellation = null;
    for (final source in _dates) {
      source.cancelPendingDateLookup();
    }
  }

  @override
  void selectLatest() {
    _windowRevision++;
    _checkActive();
    cancelPendingEventLookup();
    cancelPendingDateLookup();
    for (final source in _dates) {
      source.selectLatest();
    }
    for (final source
        in _sources.values.whereType<RoomWindowedTimelineSource>()) {
      if (source is! RoomHistoryDateCapability) {
        source.selectLatest();
      }
    }
    _mergedWindow?.latest();
  }

  @override
  String? anchorForDay(DateTime localDay) {
    for (final entry in _sources.entries) {
      if (entry.value is! RoomHistoryDateCapability) continue;
      final anchor =
          (entry.value as RoomHistoryDateCapability).anchorForDay(localDay);
      if (anchor != null) {
        _eventSources[anchor] = entry.key;
        return anchor;
      }
    }
    return null;
  }

  @override
  Future<RoomHistoryMonthDays> loadMonthDays(CalendarMonth month) async {
    _checkActive();
    if (_monthCancellation != null) {
      cancelMonthLookup();
    } else {
      _monthGeneration++;
    }
    final generation = _monthGeneration;
    final cancellation = _monthCancellation = Completer<void>();
    try {
      return await Future.any<RoomHistoryMonthDays>([
        _loadMonthDays(month, generation),
        cancellation.future.then<RoomHistoryMonthDays>(
            (_) => throw const RoomHistoryLookupCancelled()),
      ]).timeout(_queryBudget, onTimeout: () {
        if (generation == _monthGeneration) cancelMonthLookup();
        throw const RoomHistoryLookupIncomplete();
      });
    } finally {
      if (identical(_monthCancellation, cancellation)) {
        _monthCancellation = null;
      }
    }
  }

  Future<RoomHistoryMonthDays> _loadMonthDays(
      CalendarMonth month, int generation) async {
    final results = await Future.wait(_sources.entries.map((entry) async {
      if (entry.value is! RoomHistoryDateCapability) {
        return RoomHistoryMonthDays(month: month);
      }
      final result =
          await (entry.value as RoomHistoryDateCapability).loadMonthDays(month);
      if (_disposed || generation != _monthGeneration) {
        throw const RoomHistoryLookupCancelled();
      }
      for (final eventId in result.anchors.values) {
        _eventSources[eventId] = entry.key;
      }
      return result;
    }));
    if (_disposed || generation != _monthGeneration) {
      throw const RoomHistoryLookupCancelled();
    }
    final states = <int, RoomHistoryDayState>{};
    final anchors = <int, String>{};
    for (var day = 1; day <= month.daysInMonth; day++) {
      final sourceStates = results
          .map((result) => result.dayStates[day] ?? RoomHistoryDayState.unknown)
          .toList();
      states[day] = sourceStates.contains(RoomHistoryDayState.knownPresent)
          ? RoomHistoryDayState.knownPresent
          : sourceStates
                  .every((state) => state == RoomHistoryDayState.knownEmpty)
              ? RoomHistoryDayState.knownEmpty
              : sourceStates.contains(RoomHistoryDayState.error)
                  ? RoomHistoryDayState.error
                  : sourceStates.contains(RoomHistoryDayState.loading)
                      ? RoomHistoryDayState.loading
                      : RoomHistoryDayState.unknown;
      for (final result in results) {
        final anchor = result.anchors[day];
        if (anchor != null) {
          anchors[day] = anchor;
          break;
        }
      }
    }
    final earliest = results
        .map((result) => result.earliestDay)
        .whereType<DateTime>()
        .toList()
      ..sort();
    return RoomHistoryMonthDays(
        month: month,
        dayStates: states,
        anchors: anchors,
        coverageComplete: results.every((result) => result.coverageComplete),
        earliestDay: results.every((result) => result.earliestDay != null)
            ? earliest.firstOrNull
            : null,
        error: results
            .map((result) => result.error)
            .whereType<Object>()
            .firstOrNull);
  }

  @override
  void cancelMonthLookup() {
    _monthGeneration++;
    _monthCancellation?.complete();
    _monthCancellation = null;
    for (final source in _dates) {
      source.cancelMonthLookup();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final reader in _historyReaders.toList()) {
      reader.dispose();
    }
    _dateGeneration++;
    _monthGeneration++;
    _dateCancellation?.complete();
    _dateCancellation = null;
    _monthCancellation?.complete();
    _monthCancellation = null;
    Object? failure;
    StackTrace? failureStack;
    try {
      for (final source in _sources.values.toSet()) {
        try {
          source.dispose();
        } catch (error, stack) {
          failure ??= error;
          failureStack ??= stack;
        }
      }
    } finally {
      _eventSources.clear();
      _merger.clear();
      _onDispose?.call();
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
  }
}
