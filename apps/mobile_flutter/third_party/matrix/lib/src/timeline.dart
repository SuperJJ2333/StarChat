/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020, 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';

/// Represents the timeline of a room. The callback [onUpdate] will be triggered
/// automatically. The initial
/// event list will be retreived when created by the `room.getTimeline()` method.

class Timeline {
  final Room room;
  List<Event> get events => chunk.events;
  int _presentationRevision = 0;
  int get presentationRevision => _presentationRevision;

  /// Map of event ID to map of type to set of aggregated events
  final Map<String, Map<String, Set<Event>>> aggregatedEvents = {};
  final Map<String, String> _aggregationAliases = {};

  final void Function()? onUpdate;
  final void Function(int index)? onChange;
  final void Function(int index)? onInsert;
  final void Function(int index)? onRemove;
  final void Function()? onNewEvent;

  StreamSubscription<EventUpdate>? sub;
  StreamSubscription<SyncUpdate>? roomSub;
  StreamSubscription<String>? sessionIdReceivedSub;
  StreamSubscription<String>? cancelSendEventSub;
  bool isRequestingHistory = false;
  bool isRequestingFuture = false;

  bool allowNewEvent = true;
  bool isFragmentedTimeline = false;

  final Map<String, Event> _eventCache = {};

  TimelineChunk chunk;

  /// Searches for the event in this timeline. If not
  /// found, requests from the server. Requested events
  /// are cached.
  Future<Event?> getEventById(String id) async {
    for (final event in events) {
      if (event.eventId == id) return event;
    }
    if (_eventCache.containsKey(id)) return _eventCache[id];
    final requestedEvent = await room.getEventById(id);
    if (requestedEvent == null) return null;
    if (_pinnedDisposed) return requestedEvent;
    _eventCache[id] = requestedEvent;
    while (_eventCache.length > 256) {
      _eventCache.remove(_eventCache.keys.first);
    }
    return _eventCache[id];
  }

  // When fetching history, we will collect them into the `_historyUpdates` set
  // first, and then only process all events at once, once we have the full history.
  // This ensures that the entire history fetching only triggers `onUpdate` only *once*,
  // even if /sync's complete while history is being proccessed.
  bool _collectHistoryUpdates = false;

  // We confirmed, that there are no more events to load from the database.
  bool _fetchedAllDatabaseEvents = false;

  int? _pinnedGeneration;
  String? _pinnedPrevBatch;
  TimelineIdSnapshot? _pinnedIds;
  TimelineIdSnapshot? _newerIds;
  TimelineIdSnapshot? _liveOlderIds;
  bool _pinnedOpened = false;
  bool _pinnedHasMore = true;
  bool _pinnedDisposed = false;
  bool _pinnedNeedsContext = false;
  bool _pinnedOlderNeedsRebase = false;
  bool _localNewerAvailable = false;
  bool _awayFromLiveHead = false;
  int? _awayGeneration;
  int _deferredLiveRevision = 0;
  bool _contextOlderEvicted = false;
  bool _contextNewerEvicted = false;
  bool _residentEnabled = false;
  int _residentMaximum = 1000;
  final Set<String> _residentSavedIds = {};
  final Set<String> _persistedInitialIds = {};
  int? _persistedInitialGeneration;
  final Map<String, ({String eventId, String senderId, DateTime timestamp})>
      _retainedMembershipInvites = {};

  /// Actual invite facts needed by joins still in the resident window. These
  /// records retain no event bodies and are bounded by resident member joins.
  Map<String, ({String eventId, String senderId, DateTime timestamp})>
      get retainedMembershipInvites =>
          Map.unmodifiable(_retainedMembershipInvites);

  /// Activate bounded residency only when local storage can reload the rows.
  /// Call before publishing a newly opened timeline; no database means no
  /// eviction, since injected/unpersisted events have no reload authority.
  Future<void> enableResidentWindow({int maximumEvents = 1000}) async {
    if (maximumEvents < 356 || maximumEvents > 1000) {
      throw RangeError.range(maximumEvents, 356, 1000);
    }
    if (_residentEnabled || _pinnedDisposed) return;
    final database = room.client.database;
    if (database == null) return;
    final generation = room.historyGeneration;
    final candidates = events.where((e) => e.status.isSynced).toList();
    if (!await _hydrateMembers(candidates, generation)) return;
    final savedIds = generation == _persistedInitialGeneration
        ? candidates
            .map((e) => e.eventId)
            .where(_persistedInitialIds.contains)
            .toSet()
        : <String>{};
    final unverified =
        candidates.where((e) => !savedIds.contains(e.eventId)).toList();
    for (var offset = 0; offset < unverified.length; offset += 256) {
      final positions = await database.getTimelineEventPositions(
          room, unverified.skip(offset).take(256).map((e) => e.eventId));
      if (_pinnedDisposed || generation != room.historyGeneration) return;
      savedIds.addAll(positions.keys);
    }
    _residentSavedIds
      ..clear()
      ..addAll(savedIds);
    _persistedInitialIds.clear();
    _residentMaximum = maximumEvents;
    _residentEnabled = true;
    _trimResident(Direction.f);
  }

  Future<bool> _hydrateMembers(Iterable<Event> page, int generation) async {
    final database = room.client.database;
    if (database == null) return !_pinnedDisposed;
    final seen = <String>{};
    for (final event in page) {
      final sender = event.senderId;
      if (sender.isEmpty ||
          !seen.add(sender) ||
          room.getState(EventTypes.RoomMember, sender) != null) {
        continue;
      }
      final member = await database.getUser(sender, room);
      if (_pinnedDisposed ||
          (!isFragmentedTimeline && generation != room.historyGeneration)) {
        return false;
      }
      if (member != null &&
          room.getState(EventTypes.RoomMember, sender) == null) {
        room.setState(member);
        _presentationRevision++;
      }
    }
    return !_pinnedDisposed &&
        (isFragmentedTimeline || generation == room.historyGeneration);
  }

  bool _trimResident(Direction direction, {bool contextReloadable = false}) {
    if (!_residentEnabled) return false;
    final settled = events.where((e) => e.status.isSynced).toList();
    final excess = settled.length - _residentMaximum;
    if (excess <= 0) return false;
    final candidates = direction == Direction.b
        ? settled.take(excess)
        : settled.skip(_residentMaximum);
    final removed = candidates
        .where((event) =>
            contextReloadable || _residentSavedIds.contains(event.eventId))
        .toList();
    if (removed.isEmpty) return false;
    final removedIds = removed.map((e) => e.eventId).toSet();
    final requiredJoins = events
        .where((e) =>
            !removedIds.contains(e.eventId) &&
            e.type == EventTypes.RoomMember &&
            e.content['membership'] == 'join')
        .map((e) => e.stateKey)
        .whereType<String>()
        .toSet();
    for (final event in removed) {
      final member = event.stateKey;
      if (member != null &&
          requiredJoins.contains(member) &&
          event.type == EventTypes.RoomMember &&
          event.content['membership'] == 'invite') {
        _retainedMembershipInvites[member] = (
          eventId: event.eventId,
          senderId: event.senderId,
          timestamp: event.originServerTs
        );
      }
    }
    _retainedMembershipInvites
        .removeWhere((key, _) => !requiredJoins.contains(key));
    for (var index = events.length - 1; index >= 0; index--) {
      if (!removedIds.contains(events[index].eventId)) continue;
      events.removeAt(index);
      onRemove?.call(index);
    }
    for (final event in removed) {
      _eventCache.remove(event.eventId);
      _residentSavedIds.remove(event.eventId);
    }
    _rebuildAggregatedEvents();
    if (direction == Direction.b) {
      _newerIds?.dispose();
      _newerIds = null;
      if (contextReloadable) {
        _contextNewerEvicted = true;
        _localNewerAvailable = false;
      } else {
        _localNewerAvailable = true;
        if (!isFragmentedTimeline) {
          _awayFromLiveHead = true;
          _awayGeneration = room.historyGeneration;
          allowNewEvent = false;
        }
      }
    } else {
      _liveOlderIds?.dispose();
      _liveOlderIds = null;
      if (contextReloadable) {
        _contextOlderEvicted = true;
      } else {
        _pinnedOlderNeedsRebase = true;
        _pinnedHasMore = true;
        _fetchedAllDatabaseEvents = false;
      }
    }
    _presentationRevision++;
    return true;
  }

  Set<String>? _pinnedPageIds;
  final Map<String, Event> _pinnedPageRedactions = {};

  /// Retain the current reading fragment separately from the live head. The
  /// local identifier cursor is captured lazily; it never keeps extra models.
  /// A changed live fragment requires a real context token at the old edge.
  static Timeline forkHistory(
      {required Timeline source,
      required Room room,
      void Function()? onUpdate}) {
    var retainedInvites = const <String,
        ({String eventId, String senderId, DateTime timestamp})>{};
    try {
      retainedInvites = source.retainedMembershipInvites;
    } on NoSuchMethodError {
      // Legacy Timeline implementations may omit this optional facts getter.
    } on UnimplementedError {
      // Fake implementations can report an absent getter this way instead.
    }
    final fork = Timeline(
        room: room,
        chunk: TimelineChunk(events: List.of(source.events), isFragment: true),
        onUpdate: onUpdate)
      .._pinnedGeneration = room.historyGeneration
      .._pinnedPrevBatch = room.prev_batch;
    fork._retainedMembershipInvites.addAll(retainedInvites);
    return fork;
  }

  bool get canRequestHistory {
    if (_contextOlderEvicted) return true;
    if (_pinnedGeneration != null) {
      return !_pinnedOpened ||
          _pinnedNeedsContext ||
          _pinnedHasMore ||
          chunk.prevBatch.isNotEmpty;
    }
    if (isFragmentedTimeline) {
      return chunk.prevBatch.isNotEmpty &&
          events.lastOrNull?.type != EventTypes.RoomCreate;
    }
    if (events.isEmpty) return true;
    return !_fetchedAllDatabaseEvents ||
        (room.prev_batch != null && events.last.type != EventTypes.RoomCreate);
  }

  Future<void> requestHistory(
      {int historyCount = Room.defaultHistoryCount}) async {
    // Both directions mutate the same chunk and share _collectHistoryUpdates.
    // A second direction must retry after this owner has drained its update
    // batch; otherwise either finally block can publish an incomplete view.
    if (isRequestingHistory || isRequestingFuture) {
      return;
    }

    isRequestingHistory = true;
    try {
      await _requestEvents(direction: Direction.b, historyCount: historyCount);
    } finally {
      isRequestingHistory = false;
    }
  }

  Future<void> _requestPinnedEvents(int count) async {
    if (_pinnedDisposed) throw StateError('Pinned timeline disposed');
    if (!_pinnedOpened) {
      final database = room.client.database;
      final oldest = events.lastWhereOrNull((event) => event.status.isSynced);
      if (database != null &&
          oldest != null &&
          room.historyGeneration == _pinnedGeneration) {
        try {
          final handle = await database.openTimelineIdSnapshot(room,
              afterEventId: oldest.eventId);
          if (_pinnedDisposed || room.historyGeneration != _pinnedGeneration) {
            handle.dispose();
          } else {
            _pinnedIds = handle;
            chunk.prevBatch = _pinnedPrevBatch ?? '';
          }
        } on TimelineAnchorUnavailable {
          // Missing current-fragment anchor needs a real context token.
        }
      }
      if (_pinnedDisposed) throw StateError('Pinned timeline disposed');
      _pinnedOpened = true;
      _pinnedHasMore = _pinnedIds != null;
      if (_pinnedIds == null) _pinnedNeedsContext = oldest != null;
    }
    if (_pinnedIds != null && _pinnedOlderNeedsRebase) {
      final oldest = events.lastWhereOrNull((e) => e.status.isSynced);
      if (oldest != null) {
        final replacement =
            await _pinnedIds!.fork(afterEventId: oldest.eventId);
        if (_pinnedDisposed) {
          replacement.dispose();
          return;
        }
        _pinnedIds!.dispose();
        _pinnedIds = replacement;
      }
      _pinnedOlderNeedsRebase = false;
    }
    final handle = _pinnedIds;
    if (handle != null && _pinnedHasMore) {
      final ids = await handle.next(limit: count.clamp(1, 256));
      final page = <Event>[];
      _pinnedPageIds = ids.ids.toSet();
      try {
        for (final id in ids.ids) {
          final event = await room.getLocalEventById(id);
          if (_pinnedDisposed) throw StateError('Pinned timeline disposed');
          if (event == null) {
            throw StateError('Retained history event is unavailable');
          }
          page.add(event);
        }
        if (!await _hydrateMembers(page, room.historyGeneration)) return;
        handle.accept(ids);
        _appendPinnedEvents(page);
        _residentSavedIds.addAll(ids.ids);
        _pinnedHasMore = ids.hasMore;
        _trimResident(Direction.b);
      } finally {
        _pinnedPageIds = null;
        _pinnedPageRedactions.clear();
      }
      return;
    }
    if (_pinnedNeedsContext) {
      final oldest = events.lastWhereOrNull((event) => event.status.isSynced);
      if (oldest == null) return;
      final context = await room.getEventContext(oldest.eventId);
      if (_pinnedDisposed) return;
      final index = context?.events
              .indexWhere((event) => event.eventId == oldest.eventId) ??
          -1;
      if (context == null || index < 0) {
        throw StateError('Retained history context is unavailable');
      }
      // Its forward token belongs to the oldest-row context, not our retained
      // newest edge. Returning to the current live head uses selectLatest.
      _appendPinnedEvents(context.events.skip(index + 1));
      chunk.prevBatch = context.prevBatch;
      _pinnedNeedsContext = false;
      _trimResident(Direction.b, contextReloadable: true);
      return;
    }
    if (chunk.prevBatch.isNotEmpty) {
      await getRoomEvents(historyCount: count, direction: Direction.b);
    }
  }

  void _appendPinnedEvents(Iterable<Event> page) {
    final ids = events.map((event) => event.eventId).toSet();
    var changed = false;
    for (final event in page) {
      if (!ids.add(event.eventId)) continue;
      final redaction = _pinnedPageRedactions[event.eventId];
      if (redaction != null) event.setRedactionEvent(redaction);
      events.add(event);
      changed = true;
      _presentationRevision++;
      onInsert?.call(events.length - 1);
    }
    if (changed) _rebuildAggregatedEvents();
  }

  bool get canRequestFuture =>
      _localNewerAvailable ||
      _contextNewerEvicted ||
      (!allowNewEvent && chunk.nextBatch.isNotEmpty);

  Future<void> _requestLocalFuture(int count) async {
    final generation = room.historyGeneration;
    bool current() =>
        !_pinnedDisposed &&
        (isFragmentedTimeline || generation == room.historyGeneration);
    final newest = events.firstWhereOrNull((event) => event.status.isSynced);
    final database = room.client.database;
    if (newest == null || database == null) return;
    final handle = _newerIds ??= _pinnedIds != null
        ? await _pinnedIds!.fork(
            afterEventId: newest.eventId, direction: TimelineIdDirection.newer)
        : await database.openTimelineIdSnapshot(room,
            afterEventId: newest.eventId, direction: TimelineIdDirection.newer);
    try {
      if (!current()) return;
      final ids = await handle.next(limit: count.clamp(1, 256));
      final page = <Event>[];
      _pinnedPageIds = ids.ids.toSet();
      for (final id in ids.ids) {
        final event = await room.getLocalEventById(id);
        if (!current()) return;
        if (event == null) {
          throw StateError('Retained history event is unavailable');
        }
        final redaction = _pinnedPageRedactions[id];
        if (redaction != null) event.setRedactionEvent(redaction);
        page.add(event);
      }
      if (!await _hydrateMembers(page, generation) || !current()) return;
      final existing = events.map((e) => e.eventId).toSet();
      for (final event in page) {
        final redaction = _pinnedPageRedactions[event.eventId];
        if (redaction != null) event.setRedactionEvent(redaction);
      }
      final incoming =
          page.reversed.where((e) => existing.add(e.eventId)).toList();
      handle.accept(ids);
      if (incoming.isNotEmpty) {
        // Pending sends retain their own place and stable identity.
        final index = events.indexWhere((e) => e.status.isSynced);
        events.insertAll(index < 0 ? events.length : index, incoming);
        _rebuildAggregatedEvents();
        _presentationRevision++;
      }
      _residentSavedIds.addAll(ids.ids);
      _localNewerAvailable = ids.hasMore;
      _trimResident(Direction.f);
      if (_awayFromLiveHead && !ids.hasMore) {
        // A captured page may end before sync's current head. Rejoin only
        // after a small authoritative read proves adjacency; sync arriving
        // during that await invalidates the proof via this local revision.
        handle.dispose();
        _newerIds = null;
        final observedRevision = _deferredLiveRevision;
        final head = (await database.getEventList(room, limit: 1))
            .firstWhereOrNull((event) => event.status.isSynced);
        if (!current()) return;
        final residentHead =
            events.firstWhereOrNull((event) => event.status.isSynced);
        if (observedRevision == _deferredLiveRevision &&
            head?.eventId == residentHead?.eventId) {
          _awayFromLiveHead = false;
          _awayGeneration = null;
          allowNewEvent = true;
        } else {
          _localNewerAvailable = true;
        }
      }
    } on TimelineSnapshotDisposed {
      if (current()) rethrow;
    } finally {
      _pinnedPageIds = null;
      _pinnedPageRedactions.clear();
      if (!_localNewerAvailable || !current()) {
        handle.dispose();
        if (identical(_newerIds, handle)) _newerIds = null;
      }
    }
  }

  Future<void> requestFuture(
      {int historyCount = Room.defaultHistoryCount}) async {
    if (!canRequestFuture) {
      return; // we shouldn't force to add new events if they will autatically be added
    }

    if (isRequestingFuture || isRequestingHistory) return;
    isRequestingFuture = true;
    try {
      await _requestEvents(direction: Direction.f, historyCount: historyCount);
    } finally {
      isRequestingFuture = false;
    }
  }

  Future<void> _requestEvents(
      {int historyCount = Room.defaultHistoryCount,
      required Direction direction}) async {
    final generation = room.historyGeneration;
    onUpdate?.call();

    try {
      await enableResidentWindow();
      if (_pinnedDisposed) return;
      if (!isFragmentedTimeline && generation != room.historyGeneration) return;
      historyCount = historyCount.clamp(1, 256);
      if (direction == Direction.f && _localNewerAvailable) {
        await _requestLocalFuture(historyCount);
        return;
      }
      if ((direction == Direction.b && _contextOlderEvicted) ||
          (direction == Direction.f && _contextNewerEvicted)) {
        await _requestEvictedContext(direction);
        return;
      }
      if (_pinnedGeneration != null && direction == Direction.b) {
        await _requestPinnedEvents(historyCount);
        return;
      }
      if (_residentEnabled &&
          !isFragmentedTimeline &&
          await _requestResidentHistory(historyCount, generation)) {
        return;
      }
      // Compatibility path for stores without resident adoption.
      final eventsFromStore = isFragmentedTimeline
          ? null
          : _residentEnabled
              ? <Event>[]
              : await room.client.database?.getEventList(
                  room,
                  start: events.length,
                  limit: historyCount,
                );

      if (!isFragmentedTimeline && generation != room.historyGeneration) return;

      if (eventsFromStore != null && eventsFromStore.isNotEmpty) {
        // Fetch all users from database we have got here.
        for (final event in events) {
          if (room.getState(EventTypes.RoomMember, event.senderId) != null) {
            continue;
          }
          final dbUser =
              await room.client.database?.getUser(event.senderId, room);
          if (dbUser != null) room.setState(dbUser);
        }

        if (!isFragmentedTimeline && generation != room.historyGeneration) {
          return;
        }

        if (direction == Direction.b) {
          events.addAll(eventsFromStore);
          _presentationRevision++;
          final startIndex = events.length - eventsFromStore.length;
          final endIndex = events.length;
          for (var i = startIndex; i < endIndex; i++) {
            onInsert?.call(i);
          }
        } else {
          events.insertAll(0, eventsFromStore);
          _presentationRevision++;
          final startIndex = eventsFromStore.length;
          final endIndex = 0;
          for (var i = startIndex; i > endIndex; i--) {
            onInsert?.call(i);
          }
        }
        _rebuildAggregatedEvents();
      } else {
        _fetchedAllDatabaseEvents = true;
        Logs().i('No more events found in the store. Request from server...');

        if (isFragmentedTimeline) {
          await getRoomEvents(
            historyCount: historyCount,
            direction: direction,
          );
        } else {
          if (room.prev_batch == null) {
            Logs().i('No more events to request from server...');
          } else {
            await room.requestHistory(
              historyCount: historyCount,
              direction: direction,
              onHistoryReceived: () {
                _collectHistoryUpdates = true;
              },
            );
          }
        }
      }
    } finally {
      _collectHistoryUpdates = false;
      if (!_pinnedDisposed) onUpdate?.call();
    }
  }

  Future<bool> _requestResidentHistory(int count, int generation) async {
    final database = room.client.database;
    if (database == null || _fetchedAllDatabaseEvents) return false;
    final oldest = events.lastWhereOrNull((e) => e.status.isSynced);
    TimelineIdSnapshot handle;
    try {
      handle = _liveOlderIds ??= await database.openTimelineIdSnapshot(room,
          afterEventId: oldest?.eventId);
    } on TimelineAnchorUnavailable {
      if (_pinnedDisposed || generation != room.historyGeneration) return true;
      // A non-persisted live head cannot address the local fragment. Continue
      // only through the room's real remote token, never an offset guess.
      _fetchedAllDatabaseEvents = true;
      return false;
    }
    bool current() =>
        !_pinnedDisposed &&
        generation == room.historyGeneration &&
        identical(_liveOlderIds, handle);
    try {
      // A sync append may move the retained edge while opening the snapshot,
      // before there is a handle for eviction to invalidate.
      if (events.lastWhereOrNull((e) => e.status.isSynced)?.eventId !=
          oldest?.eventId) {
        if (identical(_liveOlderIds, handle)) _liveOlderIds = null;
        return true;
      }
      if (!current()) return true;
      final ids = await handle.next(limit: count);
      if (!current()) return true;
      final page = <Event>[];
      _pinnedPageIds = ids.ids.toSet();
      for (final id in ids.ids) {
        final event = await room.getLocalEventById(id);
        if (!current()) return true;
        if (event == null) {
          throw StateError('Retained history event is unavailable');
        }
        page.add(event);
      }
      if (!await _hydrateMembers(page, generation) || !current()) return true;
      handle.accept(ids);
      _appendPinnedEvents(page);
      _residentSavedIds.addAll(ids.ids);
      _fetchedAllDatabaseEvents = !ids.hasMore;
      _trimResident(Direction.b);
      return ids.rawCount > 0 || ids.hasMore;
    } on TimelineSnapshotDisposed {
      if (current()) rethrow;
      return true;
    } finally {
      _pinnedPageIds = null;
      _pinnedPageRedactions.clear();
      if (_fetchedAllDatabaseEvents || !current()) {
        handle.dispose();
        if (identical(_liveOlderIds, handle)) _liveOlderIds = null;
      }
    }
  }

  /// An evicted remote edge must be re-anchored with a real /context response.
  /// Its matching edge token is installed only after the anchor is verified;
  /// failure/disposal leaves the resident window and continuation untouched.
  Future<void> _requestEvictedContext(Direction direction) async {
    final anchor = direction == Direction.b
        ? events.lastWhereOrNull((e) => e.status.isSynced)
        : events.firstWhereOrNull((e) => e.status.isSynced);
    if (anchor == null) return;
    final context = await room.getEventContext(anchor.eventId);
    if (_pinnedDisposed) return;
    final index =
        context?.events.indexWhere((e) => e.eventId == anchor.eventId) ?? -1;
    if (context == null || index < 0) {
      throw StateError('Retained history context is unavailable');
    }
    if (direction == Direction.b) {
      _appendPinnedEvents(context.events.skip(index + 1));
      chunk.prevBatch = context.prevBatch;
      _contextOlderEvicted = false;
    } else {
      final existing = events.map((e) => e.eventId).toSet();
      final page = context.events
          .take(index)
          .where((e) => existing.add(e.eventId))
          .toList();
      final insertion = events.indexWhere((e) => e.status.isSynced);
      events.insertAll(insertion < 0 ? events.length : insertion, page);
      _rebuildAggregatedEvents();
      if (page.isNotEmpty) _presentationRevision++;
      chunk.nextBatch = context.nextBatch;
      _contextNewerEvicted = false;
    }
    if (!_trimResident(direction, contextReloadable: true)) {
      _rebuildAggregatedEvents();
    }
  }

  /// Request more previous events from the server. [historyCount] defines how much events should
  /// be received maximum. When the request is answered, [onHistoryReceived] will be triggered **before**
  /// the historical events will be published in the onEvent stream.
  /// Returns the actual count of received timeline events.
  Future<int> getRoomEvents(
      {int historyCount = Room.defaultHistoryCount,
      direction = Direction.b}) async {
    final resp = await room.client.getRoomEvents(
      room.id,
      direction,
      from: direction == Direction.b ? chunk.prevBatch : chunk.nextBatch,
      limit: historyCount,
      filter: jsonEncode(StateFilter(lazyLoadMembers: true).toJson()),
    );
    if (_pinnedDisposed) return 0;

    if (resp.end == null) {
      Logs().w('We reached the end of the timeline');
    }

    final newNextBatch = direction == Direction.b ? resp.start : resp.end;
    final newPrevBatch = direction == Direction.b ? resp.end : resp.start;

    final type = direction == Direction.b
        ? EventUpdateType.history
        : EventUpdateType.timeline;

    if ((resp.state?.length ?? 0) == 0 &&
        resp.start != resp.end &&
        newPrevBatch != null &&
        newNextBatch != null) {
      if (type == EventUpdateType.history) {
        Logs().w(
            '[nav] we can still request history prevBatch: $type $newPrevBatch');
      } else {
        Logs().w(
            '[nav] we can still request timeline nextBatch: $type $newNextBatch');
      }
    }

    final newEvents =
        resp.chunk.map((e) => Event.fromMatrixEvent(e, room)).toList();

    if (!allowNewEvent && !isFragmentedTimeline) {
      if (resp.start == resp.end ||
          (resp.end == null && direction == Direction.f)) {
        allowNewEvent = true;
      }

      if (allowNewEvent) {
        Logs().d('We now allow sync update into the timeline.');
        newEvents.addAll(
            await room.client.database?.getEventList(room, onlySending: true) ??
                []);
      }
    }

    // Try to decrypt encrypted events but don't update the database.
    if (room.encrypted && room.client.encryptionEnabled) {
      for (var i = 0; i < newEvents.length; i++) {
        if (newEvents[i].type == EventTypes.Encrypted) {
          newEvents[i] = await room.client.encryption!.decryptRoomEvent(
            room.id,
            newEvents[i],
          );
        }
      }
    }
    if (_pinnedDisposed) return 0;

    // Context pages can overlap. Preserve the already loaded Event instance so
    // a late original cannot duplicate or undo a locally observed redaction.
    final loadedById = {for (final event in events) event.eventId: event};
    newEvents.removeWhere((event) {
      final loaded = loadedById[event.eventId];
      if (loaded == null) {
        loadedById[event.eventId] = event;
        return false;
      }
      // A paging response may be the first authoritative redaction seen for
      // an already decrypted event. Merge only that state; replacing the
      // complete Event would discard the decrypted payload.
      if (event.redacted && !loaded.redacted) {
        final redaction = event.redactedBecause;
        if (redaction != null) {
          removeAggregatedEvent(loaded);
          loaded.setRedactionEvent(redaction);
          _presentationRevision++;
          final index = events.indexOf(loaded);
          if (index >= 0) onChange?.call(index);
        }
      }
      return true;
    });

    // update chunk anchors
    if (newEvents.isNotEmpty) _presentationRevision++;
    if (type == EventUpdateType.history) {
      chunk.prevBatch = newPrevBatch ?? '';

      final offset = chunk.events.length;

      chunk.events.addAll(newEvents);

      for (var i = 0; i < newEvents.length; i++) {
        onInsert?.call(i + offset);
      }
    } else {
      chunk.nextBatch = newNextBatch ?? '';
      chunk.events.insertAll(0, newEvents.reversed);

      for (var i = 0; i < newEvents.length; i++) {
        onInsert?.call(i);
      }
    }

    if (!_trimResident(direction, contextReloadable: true)) {
      _rebuildAggregatedEvents();
    }
    if (onUpdate != null) {
      onUpdate!();
    }
    return resp.chunk.length;
  }

  Timeline(
      {required this.room,
      this.onUpdate,
      this.onChange,
      this.onInsert,
      this.onRemove,
      this.onNewEvent,
      Iterable<String> persistedInitialIds = const [],
      required this.chunk}) {
    _persistedInitialIds.addAll(persistedInitialIds.take(1000));
    _persistedInitialGeneration = room.historyGeneration;
    sub = room.client.onEvent.stream.listen(_handleEventUpdate);

    // If the timeline is limited we want to clear our events cache
    roomSub = room.client.onSync.stream
        .where((sync) =>
            !isFragmentedTimeline &&
            sync.rooms?.join?[room.id]?.timeline?.limited == true)
        .listen(_removeEventsNotInThisSync);

    sessionIdReceivedSub =
        room.onSessionKeyReceived.stream.listen(_sessionKeyReceived);
    cancelSendEventSub =
        room.client.onCancelSendEvent.stream.listen(_cleanUpCancelledEvent);

    // we want to populate our aggregated events
    _rebuildAggregatedEvents();

    // we are using a fragmented timeline
    if (chunk.isFragment || chunk.nextBatch != '') {
      allowNewEvent = false;
      isFragmentedTimeline = true;
      // fragmented timelines never read from the database.
      _fetchedAllDatabaseEvents = true;
    }
  }

  void _cleanUpCancelledEvent(String eventId) {
    final i = _findEvent(event_id: eventId);
    if (i < events.length) {
      _residentSavedIds.remove(events[i].eventId);
      events.removeAt(i);
      _rebuildAggregatedEvents();
      _presentationRevision++;
      onRemove?.call(i);
      onUpdate?.call();
    }
  }

  /// Removes all entries from [events] which are not in this SyncUpdate.
  void _removeEventsNotInThisSync(SyncUpdate sync) {
    final newSyncEvents = sync.rooms?.join?[room.id]?.timeline?.events ?? [];
    final keepEventIds = newSyncEvents.map((e) => e.eventId);
    final before = events.length;
    final hadInviteDependencies = _retainedMembershipInvites.isNotEmpty;
    events.removeWhere(
        (e) => e.status.isSynced && !keepEventIds.contains(e.eventId));
    _liveOlderIds?.dispose();
    _liveOlderIds = null;
    _eventCache.clear();
    aggregatedEvents.clear();
    _retainedMembershipInvites.clear();
    _newerIds?.dispose();
    _newerIds = null;
    _localNewerAvailable = false;
    _awayFromLiveHead = false;
    _awayGeneration = null;
    allowNewEvent = true;
    _fetchedAllDatabaseEvents = false;
    _residentSavedIds.retainAll(events.map((e) => e.eventId));
    _rebuildAggregatedEvents();
    if (events.length != before || hadInviteDependencies) {
      _presentationRevision++;
    }
  }

  /// Don't forget to call this before you dismiss this object!
  void cancelSubscriptions() {
    _pinnedDisposed = true;
    _pinnedIds?.dispose();
    _pinnedIds = null;
    _newerIds?.dispose();
    _newerIds = null;
    _liveOlderIds?.dispose();
    _liveOlderIds = null;
    _eventCache.clear();
    _aggregationAliases.clear();
    aggregatedEvents.clear();
    _retainedMembershipInvites.clear();
    // ignore: discarded_futures
    sub?.cancel();
    // ignore: discarded_futures
    roomSub?.cancel();
    // ignore: discarded_futures
    sessionIdReceivedSub?.cancel();
    // ignore: discarded_futures
    cancelSendEventSub?.cancel();
  }

  /// Compatibility hook after [enableResidentWindow] has verified persistence.
  /// Unverified sources are never synchronously discarded.
  void trimLiveHistory({required int maximumEvents}) {
    if (maximumEvents <= 0) throw ArgumentError.value(maximumEvents);
    if (_residentEnabled &&
        !isFragmentedTimeline &&
        !isRequestingHistory &&
        !isRequestingFuture) {
      _trimResident(Direction.f);
    }
  }

  void _sessionKeyReceived(String sessionId) async {
    var decryptAtLeastOneEvent = false;
    Future<void> decryptFn() async {
      final encryption = room.client.encryption;
      if (!room.client.encryptionEnabled || encryption == null) {
        return;
      }
      for (final original in List<Event>.of(events)) {
        if (_pinnedDisposed) return;
        if (original.type == EventTypes.Encrypted &&
            original.messageType == MessageTypes.BadEncrypted &&
            original.content['session_id'] == sessionId) {
          final decrypted = await encryption.decryptRoomEvent(
            room.id,
            original,
            store: true,
            updateType: EventUpdateType.history,
          );
          if (_pinnedDisposed) return;
          final index =
              events.indexWhere((event) => identical(event, original));
          // A sync replacement, redaction, eviction or cancellation wins over
          // this in-flight decode. Never write through a stale list index.
          if (index < 0 || original.redacted) continue;
          events[index] = decrypted;
          _presentationRevision++;
          _rebuildAggregatedEvents();
          onChange?.call(index);
          if (decrypted.type != EventTypes.Encrypted) {
            decryptAtLeastOneEvent = true;
          }
        }
      }
    }

    final database = room.client.database;
    if (database != null) {
      await database.prepareTimelineStorage([room.id]);
      if (_pinnedDisposed) return;
      await database.transaction(decryptFn);
    } else {
      await decryptFn();
    }
    if (decryptAtLeastOneEvent && !_pinnedDisposed) onUpdate?.call();
  }

  /// Request the keys for undecryptable events of this timeline
  void requestKeys({
    bool tryOnlineBackup = true,
    bool onlineKeyBackupOnly = true,
  }) {
    for (final event in events) {
      if (event.type == EventTypes.Encrypted &&
          event.messageType == MessageTypes.BadEncrypted &&
          event.content['can_request_session'] == true) {
        final sessionId = event.content.tryGet<String>('session_id');
        final senderKey = event.content.tryGet<String>('sender_key');
        if (sessionId != null && senderKey != null) {
          room.client.encryption?.keyManager.maybeAutoRequest(
            room.id,
            sessionId,
            senderKey,
            tryOnlineBackup: tryOnlineBackup,
            onlineKeyBackupOnly: onlineKeyBackupOnly,
          );
        }
      }
    }
  }

  /// Set the read marker to the last synced event in this timeline.
  Future<void> setReadMarker({String? eventId, bool? public}) async {
    eventId ??=
        events.firstWhereOrNull((event) => event.status.isSynced)?.eventId;
    if (eventId == null) return;
    return room.setReadMarker(eventId, mRead: eventId, public: public);
  }

  int _findEvent({String? event_id, String? unsigned_txid}) {
    // we want to find any existing event where either the passed event_id or the passed unsigned_txid
    // matches either the event_id or transaction_id of the existing event.
    // For that we create two sets, searchNeedle, what we search, and searchHaystack, where we check if there is a match.
    // Now, after having these two sets, if the intersect between them is non-empty, we know that we have at least one match in one pair,
    // thus meaning we found our element.
    final searchNeedle = <String>{};
    if (event_id != null) {
      searchNeedle.add(event_id);
    }
    if (unsigned_txid != null) {
      searchNeedle.add(unsigned_txid);
    }
    int i;
    for (i = 0; i < events.length; i++) {
      final searchHaystack = <String>{events[i].eventId};

      final txnid = events[i].unsigned?.tryGet<String>('transaction_id');
      if (txnid != null) {
        searchHaystack.add(txnid);
      }
      if (searchNeedle.intersection(searchHaystack).isNotEmpty) {
        break;
      }
    }
    return i;
  }

  void _removeEventFromSet(Set<Event> eventSet, Event event) {
    eventSet.removeWhere((e) =>
        e.matchesEventOrTransactionId(event.eventId) ||
        event.unsigned != null &&
            e.matchesEventOrTransactionId(
                event.unsigned?.tryGet<String>('transaction_id')));
  }

  /// Aggregations describe loaded events, not all historical relations. Build
  /// once per resident mutation so opposite-edge eviction cannot discard a
  /// still-loaded contribution or leave an ever-growing empty target map.
  void _rebuildAggregatedEvents() {
    final ids = events.map((event) => event.eventId).toSet();
    _aggregationAliases.removeWhere((id, _) => !ids.contains(id));
    final canonical = <String, Event>{};
    final redactedTargets = <String>{};
    for (final event in events) {
      final transactionId = event.unsigned?.tryGet<String>('transaction_id');
      if (transactionId != null) {
        _aggregationAliases[event.eventId] = transactionId;
      }
      final identity = _aggregationAliases[event.eventId] ?? event.eventId;
      final previous = canonical[identity];
      if (previous == null ||
          event.status.intValue > previous.status.intValue) {
        canonical[identity] = event;
      }
      if (event.redacted) redactedTargets.add(event.eventId);
    }
    aggregatedEvents.clear();
    for (final event in canonical.values) {
      final target = event.relationshipEventId;
      final type = event.relationshipType;
      if (event.redacted ||
          target == null ||
          type == null ||
          redactedTargets.contains(target)) {
        continue;
      }
      ((aggregatedEvents[target] ??= {})[type] ??= <Event>{}).add(event);
    }
  }

  void addAggregatedEvent(Event event) {
    // we want to add an event to the aggregation tree
    final relationshipType = event.relationshipType;
    final relationshipEventId = event.relationshipEventId;
    if (relationshipType == null || relationshipEventId == null) {
      return; // nothing to do
    }
    final events = (aggregatedEvents[relationshipEventId] ??=
        <String, Set<Event>>{})[relationshipType] ??= <Event>{};
    // remove a potential old event
    _removeEventFromSet(events, event);
    // add the new one
    events.add(event);
    _presentationRevision++;
    if (onChange != null) {
      final index = _findEvent(event_id: relationshipEventId);
      onChange?.call(index);
    }
  }

  void removeAggregatedEvent(Event event) {
    aggregatedEvents.remove(event.eventId);
    if (event.unsigned != null) {
      aggregatedEvents.remove(event.unsigned?['transaction_id']);
    }
    for (final types in aggregatedEvents.values) {
      for (final events in types.values) {
        _removeEventFromSet(events, event);
      }
    }
  }

  void _handleEventUpdate(EventUpdate eventUpdate, {bool update = true}) {
    try {
      if (eventUpdate.roomID != room.id) return;

      // A limited sync's event stream can precede its onSync callback. Its
      // newly authoritative head belongs to a different generation and must
      // be admitted before the callback discards the old resident fragment.
      if (_awayFromLiveHead && _awayGeneration != room.historyGeneration) {
        _awayFromLiveHead = false;
        _awayGeneration = null;
        allowNewEvent = true;
      }

      if (eventUpdate.type != EventUpdateType.timeline &&
          eventUpdate.type != EventUpdateType.history) {
        return;
      }

      if (eventUpdate.type == EventUpdateType.timeline) {
        onNewEvent?.call();
      }

      final i = _findEvent(
          event_id: eventUpdate.content['event_id'],
          unsigned_txid: eventUpdate.content['unsigned'] is Map
              ? eventUpdate.content['unsigned']['transaction_id']
              : null);
      final isRedaction = eventUpdate.content['type'] == EventTypes.Redaction;
      final redactionContent = eventUpdate.content['content'];
      final redactionTarget = isRedaction
          ? eventUpdate.content['redacts'] as String? ??
              (redactionContent is Map
                  ? redactionContent['redacts'] as String?
                  : null)
          : null;
      if (redactionTarget != null &&
          _pinnedPageIds?.contains(redactionTarget) == true) {
        // A cached row can already be read while another row still awaits
        // the store. Replay authoritative recalls before publishing the page.
        _pinnedPageRedactions[redactionTarget] =
            Event.fromJson(eventUpdate.content, room);
      }
      final updatesLoadedEvent = i < events.length ||
          redactionTarget != null &&
              _findEvent(event_id: redactionTarget) < events.length;
      final status = eventStatusFromInt(eventUpdate.content['status'] ??
          (eventUpdate.content['unsigned'] is Map<String, dynamic>
              ? eventUpdate.content['unsigned'][messageSendingStatusKey]
              : null) ??
          EventStatus.synced.intValue);
      if (!allowNewEvent && !updatesLoadedEvent && status.isSynced) {
        if (_awayFromLiveHead && eventUpdate.type == EventUpdateType.timeline) {
          _deferredLiveRevision++;
        }
        return;
      }
      // SDK emits these updates after its authoritative database write. Local
      // sends remain separately owned until the first synced confirmation.
      if (_residentEnabled &&
          (allowNewEvent || updatesLoadedEvent) &&
          status.isSynced) {
        final id = eventUpdate.content['event_id'];
        if (id is String) _residentSavedIds.add(id);
      }

      if (i < events.length) {
        // /sync can beat the HTTP send response. A late local ACK/error still
        // contains the device timestamp and unconfirmed payload: never replace
        // an authoritative synced event with that older local projection.
        if (events[i].status.isSynced && !status.isSynced) return;
        // if the old status is larger than the new one, we also want to preserve the old status
        final oldStatus = events[i].status;
        final priorRedaction = events[i].redactedBecause;
        events[i] = Event.fromJson(
          eventUpdate.content,
          room,
        );
        _presentationRevision++;
        // A delayed history/decryption result cannot undo a server redaction.
        if (priorRedaction != null && !events[i].redacted) {
          events[i].setRedactionEvent(priorRedaction);
        }
        // do we preserve the status? we should allow 0 -> -1 updates and status increases
        if ((latestEventStatus(status, oldStatus) == oldStatus) &&
            !(status.isError && oldStatus.isSending)) {
          events[i].status = oldStatus;
        }
        onChange?.call(i);
      } else if (allowNewEvent || !isRedaction) {
        final newEvent = Event.fromJson(
          eventUpdate.content,
          room,
        );
        _presentationRevision++;

        if (eventUpdate.type == EventUpdateType.history &&
            events.indexWhere(
                    (e) => e.eventId == eventUpdate.content['event_id']) !=
                -1) {
          return;
        }
        var index = events.length;
        if (eventUpdate.type == EventUpdateType.history) {
          events.add(newEvent);
        } else {
          index = events.firstIndexWhereNotError;
          events.insert(index, newEvent);
        }
        onInsert?.call(index);
      }

      // Handle redaction events
      if (eventUpdate.content['type'] == EventTypes.Redaction) {
        final redaction = Event.fromJson(eventUpdate.content, room);
        final target = eventUpdate.content.tryGet<String>('redacts') ??
            redaction.content.tryGet<String>('redacts');
        final index =
            target == null ? events.length : _findEvent(event_id: target);
        if (index < events.length) {
          removeAggregatedEvent(events[index]);

          // Is the redacted event a reaction? Then update the event this
          // belongs to:
          if (onChange != null) {
            final relationshipEventId = events[index].relationshipEventId;
            if (relationshipEventId != null) {
              onChange?.call(_findEvent(event_id: relationshipEventId));
            }
          }

          events[index].setRedactionEvent(Event.fromJson(
            eventUpdate.content,
            room,
          ));
          _presentationRevision++;
          onChange?.call(index);
        }
      }

      if (!_trimResident(eventUpdate.type == EventUpdateType.history
          ? Direction.b
          : Direction.f)) {
        _rebuildAggregatedEvents();
      }
      _residentSavedIds.retainAll(events.map((event) => event.eventId));
      final residentJoins = events
          .where((e) =>
              e.type == EventTypes.RoomMember &&
              e.content['membership'] == 'join')
          .map((e) => e.stateKey)
          .toSet();
      _retainedMembershipInvites
          .removeWhere((key, _) => !residentJoins.contains(key));
      if (update && !_collectHistoryUpdates && !_pinnedDisposed) {
        onUpdate?.call();
      }
    } catch (e, s) {
      Logs().w('Handle event update failed', e, s);
    }
  }

  @Deprecated('Use [startSearch] instead.')
  Stream<List<Event>> searchEvent({
    String? searchTerm,
    int requestHistoryCount = 100,
    int maxHistoryRequests = 10,
    String? sinceEventId,
    int? limit,
    bool Function(Event)? searchFunc,
  }) =>
      startSearch(
        searchTerm: searchTerm,
        requestHistoryCount: requestHistoryCount,
        maxHistoryRequests: maxHistoryRequests,
        // ignore: deprecated_member_use_from_same_package
        sinceEventId: sinceEventId,
        limit: limit,
        searchFunc: searchFunc,
      ).map((result) => result.$1);

  /// Searches [searchTerm] in this timeline. It first searches in the
  /// cache, then in the database and then on the server. The search can
  /// take a while, which is why this returns a stream so the already found
  /// events can already be displayed.
  /// Override the [searchFunc] if you need another search. This will then
  /// ignore [searchTerm].
  /// Returns the List of Events and the next prevBatch at the end of the
  /// search.
  Stream<(List<Event>, String?)> startSearch({
    String? searchTerm,
    int requestHistoryCount = 100,
    int maxHistoryRequests = 10,
    String? prevBatch,
    @Deprecated('Use [prevBatch] instead.') String? sinceEventId,
    int? limit,
    bool Function(Event)? searchFunc,
  }) async* {
    assert(searchTerm != null || searchFunc != null);
    searchFunc ??= (event) =>
        event.body.toLowerCase().contains(searchTerm?.toLowerCase() ?? '');
    final found = <Event>[];

    if (sinceEventId == null) {
      // Search locally
      for (final event in events) {
        if (searchFunc(event)) {
          yield (found..add(event), null);
        }
      }

      // Search in database
      var start = events.length;
      while (true) {
        final eventsFromStore = await room.client.database?.getEventList(
              room,
              start: start,
              limit: requestHistoryCount,
            ) ??
            [];
        if (eventsFromStore.isEmpty) break;
        start += eventsFromStore.length;
        for (final event in eventsFromStore) {
          if (searchFunc(event)) {
            yield (found..add(event), null);
          }
        }
      }
    }

    // Search on the server
    prevBatch ??= room.prev_batch;
    if (sinceEventId != null) {
      prevBatch =
          (await room.client.getEventContext(room.id, sinceEventId)).end;
    }
    final encryption = room.client.encryption;
    for (var i = 0; i < maxHistoryRequests; i++) {
      if (prevBatch == null) break;
      if (limit != null && found.length >= limit) break;
      try {
        final resp = await room.client.getRoomEvents(
          room.id,
          Direction.b,
          from: prevBatch,
          limit: requestHistoryCount,
          filter: jsonEncode(StateFilter(lazyLoadMembers: true).toJson()),
        );
        for (final matrixEvent in resp.chunk) {
          var event = Event.fromMatrixEvent(matrixEvent, room);
          if (event.type == EventTypes.Encrypted && encryption != null) {
            event = await encryption.decryptRoomEvent(room.id, event);
            if (event.type == EventTypes.Encrypted &&
                event.messageType == MessageTypes.BadEncrypted &&
                event.content['can_request_session'] == true) {
              // Await requestKey() here to ensure decrypted message bodies
              await event.requestKey();
            }
          }
          if (searchFunc(event)) {
            yield (found..add(event), resp.end);
            if (limit != null && found.length >= limit) break;
          }
        }
        prevBatch = resp.end;
        // We are at the beginning of the room
        if (resp.chunk.length < requestHistoryCount) break;
      } on MatrixException catch (e) {
        // We have no permission anymore to request the history
        if (e.error == MatrixError.M_FORBIDDEN) {
          break;
        }
        rethrow;
      }
    }
    return;
  }
}

extension on List<Event> {
  int get firstIndexWhereNotError {
    if (isEmpty) return 0;
    final index = indexWhere((event) => !event.status.isError);
    if (index == -1) return length;
    return index;
  }
}
