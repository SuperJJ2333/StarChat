import 'dart:async';
import 'dart:typed_data';

import 'incremental_timeline_merge.dart';

import 'matrix_room_timeline_adapter.dart';
import 'room_history_date_capability.dart';
import 'room_timeline_controller.dart';

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
        RoomHistoryStatus,
        RoomFutureHistoryStatus,
        RoomMessageLookupSource,
        RoomVisibleReadCapability,
        RoomEventSourceCapability,
        RoomHistoryDateCapability {
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
  bool _sourceIndexReady = false;
  final _merger = IncrementalTimelineMerge<RoomMessageViewModel>(
    idOf: (event) => event.id,
    compare: (a, b) {
      final order = a.timestamp.compareTo(b.timestamp);
      return order != 0 ? order : a.id.compareTo(b.id);
    },
  );
  bool _disposed = false;
  int _dateGeneration = 0, _monthGeneration = 0;
  Completer<void>? _dateCancellation, _monthCancellation;
  static const _queryBudget = Duration(seconds: 13);
  RoomTimelineCapability get _primary => _sources[primaryRoomId]!;

  /// Ownership transfers only on success; callers dispose rejected sources.
  void addSource(String roomId, RoomTimelineCapability source) {
    _checkActive();
    if (_sources.containsKey(roomId)) {
      if (identical(_sources[roomId], source)) return;
      throw StateError('Conversation source already attached');
    }
    _sources[roomId] = source;
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
  }

  void _checkActive() {
    if (_disposed) throw StateError('Conversation timeline is disposed');
  }

  @override
  List<RoomMessageViewModel> snapshot() {
    _checkActive();
    final events = <String, RoomMessageViewModel>{};
    for (final entry in _sources.entries) {
      for (final event in entry.value.snapshot()) {
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
  Future<void> retry(String transactionId) async {
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
    await _primary.retry(transactionId);
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
    _checkActive();
    cancelPendingDateLookup();
    for (final source in _dates) {
      source.selectLatest();
    }
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
