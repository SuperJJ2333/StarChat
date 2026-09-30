import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'unread_mention_tracker.dart';
import 'local_hidden_events.dart';

/// Device-local event identities only; never stores message content.
final class RoomMentionStore extends ChangeNotifier {
  RoomMentionStore(
      {this.maxObservationRooms = 8, this.maxObservationEvents = 4096})
      : assert(maxObservationRooms > 0),
        assert(maxObservationEvents > 0);
  final int maxObservationRooms, maxObservationEvents;
  @visibleForTesting
  int get observationRoomCount => _eventVersions.length;
  @visibleForTesting
  int observationEventCount(Room room) =>
      _eventVersions[_key(room)]?.length ?? 0;
  void invalidateObservation(Room room) {
    _eventVersions.remove(_key(room));
    _bounds.remove(_key(room));
  }

  static final shared = RoomMentionStore();
  final _states = <String, UnreadMentionTracker>{};
  final _opening = <String, Future<UnreadMentionTracker>>{};
  // Weak identity checks never retain Event -> Room -> Client or decrypted
  // message content. The bounded maps retain only IDs and visibility metadata.
  final _eventVersions =
      <String, Map<String, (WeakReference<Event>, bool, bool)>>{};
  final _bounds = <String, (int, String?, String?)>{};
  String _key(Room room) => 'chat-mentions-v2:${room.client.userID}:${room.id}';

  bool hasPending(Room room) =>
      !room.isDirectChat && (_states[_key(room)]?.hasPending ?? false);

  static void _check(bool Function()? shouldContinue) {
    if (shouldContinue != null && !shouldContinue()) {
      throw const _MentionScanCanceled();
    }
  }

  Future<UnreadMentionTracker> open(Room room,
      {bool Function()? shouldContinue}) async {
    _check(shouldContinue);
    final key = _key(room);
    try {
      final state = await _opening.putIfAbsent(key, () async {
        final prefs = await SharedPreferences.getInstance();
        _check(shouldContinue);
        final restored =
            UnreadMentionTracker.decode(prefs.getString(_key(room)));
        final state = restored ??
            UnreadMentionTracker(
                accountId: room.client.userID ?? '', roomId: room.id);
        if (restored == null) {
          state.initializeEventBoundary(room.fullyRead);
        }
        _check(shouldContinue);
        await prefs.setString(key, state.encode());
        _check(shouldContinue);
        _states[key] = state;
        return state;
      });
      _check(shouldContinue);
      return state;
    } catch (_) {
      _opening.remove(key);
      rethrow;
    }
  }

  Future<void> ingest(Room room, Iterable<Event> events,
      {bool Function()? shouldContinue, Set<String>? changedEventIds}) async {
    try {
      _check(shouldContinue);
      if (room.isDirectChat) return;
      final state = await open(room, shouldContinue: shouldContinue);
      _check(shouldContinue);
      final localHistory = SharedPreferencesLocalHiddenEvents(
          preferences: await SharedPreferences.getInstance(),
          accountId: room.client.userID ?? '');
      _check(shouldContinue);
      final isLocallyHidden = localHistory.readFilter(room.id);
      final ordered = events is List<Event> ? events : events.toList();
      final key = _key(room);
      final previous = _bounds[key];
      final head = ordered.firstOrNull?.eventId;
      final tail = ordered.lastOrNull?.eventId;
      final difference = ordered.length - (previous?.$1 ?? 0);
      final registration =
          previous != null && difference > 0 && tail == previous.$3
              ? ordered.take(difference + 1)
              : previous != null && difference > 0 && head == previous.$2
                  ? ordered.skip(previous.$1 > 0 ? previous.$1 - 1 : 0)
                  : previous != null &&
                          difference == 0 &&
                          head == previous.$2 &&
                          tail == previous.$3
                      ? const <Event>[]
                      : ordered;
      final registrationIds =
          registration.map((event) => event.eventId).toList();
      final newlyRegistered = {
        for (final id in registrationIds)
          if (!state.hasEventOrder(id)) id
      };
      var changed = state.registerTimeline(registrationIds);
      _bounds[key] = (ordered.length, head, tail);
      final versions = _eventVersions.remove(key) ??
          <String, (WeakReference<Event>, bool, bool)>{};
      _eventVersions[key] = versions;
      while (_eventVersions.length > maxObservationRooms) {
        final oldest = _eventVersions.keys.first;
        _eventVersions.remove(oldest);
        _bounds.remove(oldest);
      }
      for (final event in ordered.reversed) {
        final hidden = isLocallyHidden(event.eventId, event.originServerTs);
        final redacted = event.redacted;
        final before = versions[event.eventId];
        if (before != null &&
            identical(before.$1.target, event) &&
            before.$2 == redacted &&
            before.$3 == hidden &&
            !(changedEventIds?.contains(event.eventId) ?? false)) {
          continue;
        }
        if (before == null &&
            previous != null &&
            changedEventIds != null &&
            !newlyRegistered.contains(event.eventId) &&
            !changedEventIds.contains(event.eventId) &&
            !redacted &&
            !hidden) {
          // Older unchanged rows need no payload parsing or identity cache.
          // Live/decrypted/recall IDs arrive through the public event stream;
          // overflow or an initial scan passes null to inspect every row.
          continue;
        }
        versions.remove(event.eventId);
        versions[event.eventId] = (WeakReference(event), redacted, hidden);
        while (versions.length > maxObservationEvents) {
          versions.remove(versions.keys.first);
        }
        if (!state.hasEventOrder(event.eventId)) {
          changed = state.registerTimeline(
                  ordered.map((event) => event.eventId).toList()) ||
              changed;
        }
        if (redacted || hidden) {
          changed = state.onRedacted(event.eventId) || changed;
          continue;
        }
        if (event.type != EventTypes.Message) continue;
        final mentions = event.content['m.mentions'];
        final targets = <String>{};
        if (mentions is Map) {
          final users = mentions['user_ids'];
          if (users is List) targets.addAll(users.whereType<String>());
          if (mentions['room'] == true) targets.add(state.accountId);
        }
        changed = state.onMessageArrived(
                eventId: event.eventId,
                order: state.orderFor(event.eventId),
                senderIsSelf: event.senderId == state.accountId,
                mentionedUserIds: targets) ||
            changed;
      }
      if (changed) {
        await save(room, shouldContinue: shouldContinue);
      }
      if (versions.length > ordered.length) {
        final retained = {for (final event in ordered) event.eventId};
        versions.removeWhere((id, _) => !retained.contains(id));
      }
    } on _MentionScanCanceled {
      // Revoked sessions do not publish or persist further mention updates.
    }
  }

  Future<void> clearForLocalHistory(Room room,
      {String? boundaryEventId, bool Function()? shouldContinue}) async {
    if (room.isDirectChat) return;
    final state = await open(room, shouldContinue: shouldContinue);
    _check(shouldContinue);
    for (final eventId in state.pendingEventIdsNewestFirst()) {
      state.onRedacted(eventId);
    }
    // The timestamp cutoff also rejects older events not loaded at deletion.
    // Keep the scan head so the scanner need not revisit the cleared interval.
    state.boundaryEventId = boundaryEventId ?? '';
    state.completedScanHead = boundaryEventId;
    await save(room, shouldContinue: shouldContinue);
  }

  Future<void> save(Room room, {bool Function()? shouldContinue}) async {
    try {
      _check(shouldContinue);
      final state = _states[_key(room)];
      if (state == null) return;
      final prefs = await SharedPreferences.getInstance();
      _check(shouldContinue);
      await prefs.setString(_key(room), state.encode());
      _check(shouldContinue);
      notifyListeners();
    } on _MentionScanCanceled {
      // Revoked sessions do not publish or persist further mention updates.
    }
  }

  final _scanning = <String>{};
  Future<void> scan(Room room, {bool Function()? shouldContinue}) async {
    if (shouldContinue != null && !shouldContinue()) return;
    if (room.isDirectChat || !_scanning.add(_key(room))) return;
    Timeline? timeline;
    try {
      final state = await open(room, shouldContinue: shouldContinue);
      _check(shouldContinue);
      final target = state.completedScanHead ?? state.boundaryEventId;
      _check(shouldContinue);
      timeline = await room.getTimeline();
      _check(shouldContinue);
      await ingest(room, timeline.events, shouldContinue: shouldContinue);
      _check(shouldContinue);
      // Complete the unread interval, including mentions outside the first page.
      while ((target == null ||
              target.isEmpty ||
              !timeline.events.any((e) => e.eventId == target)) &&
          timeline.canRequestHistory) {
        final oldest = timeline.events.lastOrNull?.eventId;
        final token = room.prev_batch;
        _check(shouldContinue);
        await timeline.requestHistory(historyCount: 60);
        _check(shouldContinue);
        await ingest(room, timeline.events, shouldContinue: shouldContinue);
        _check(shouldContinue);
        if (oldest == timeline.events.lastOrNull?.eventId &&
            token == room.prev_batch) {
          break;
        }
      }
      if (!timeline.canRequestHistory && !state.hasKnownBoundary) {
        // A deleted/inaccessible read marker cannot suppress accessible messages forever.
        state.boundaryEventId = '';
        await ingest(room, timeline.events, shouldContinue: shouldContinue);
        _check(shouldContinue);
      }
      if (!timeline.canRequestHistory ||
          (target != null &&
              timeline.events.any((event) => event.eventId == target))) {
        _check(shouldContinue);
        state.completedScanHead = timeline.events.firstOrNull?.eventId;
        await save(room, shouldContinue: shouldContinue);
        _check(shouldContinue);
      }
    } catch (_) {
      // Preserve pending reminders; next sync retries without logging content.
    } finally {
      timeline?.cancelSubscriptions();
      _scanning.remove(_key(room));
    }
  }
}

final class MentionIngestCoalescer {
  MentionIngestCoalescer({required this.isActive, required this.ingest});
  final bool Function() isActive;
  final Future<void> Function(bool Function() shouldContinue) ingest;
  Future<void>? _running;
  bool _requested = false;
  int _generation = 0;

  Future<void> request() {
    if (!isActive()) return Future<void>.value();
    _requested = true;
    final running = _running;
    if (running != null) return running;
    final completion = Completer<void>();
    _running = completion.future;
    unawaited(_drain(completion));
    return completion.future;
  }

  Future<void> _drain(Completer<void> completion) async {
    try {
      while (_requested && isActive()) {
        _requested = false;
        final generation = _generation;
        await ingest(() => generation == _generation && isActive());
      }
      completion.complete();
    } catch (error, stack) {
      completion.completeError(error, stack);
    } finally {
      _running = null;
    }
  }

  void cancel() {
    _generation++;
    _requested = false;
  }
}

final class _MentionScanCanceled implements Exception {
  const _MentionScanCanceled();
}
