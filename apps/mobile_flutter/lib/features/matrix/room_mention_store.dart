import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'unread_mention_tracker.dart';

/// Device-local event identities only; never stores message content.
final class RoomMentionStore extends ChangeNotifier {
  static final shared = RoomMentionStore();
  final _states = <String, UnreadMentionTracker>{};
  final _opening = <String, Future<UnreadMentionTracker>>{};
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
      {bool Function()? shouldContinue}) async {
    try {
      _check(shouldContinue);
      if (room.isDirectChat) return;
      final state = await open(room, shouldContinue: shouldContinue);
      _check(shouldContinue);
      final before = state.encode();
      final ordered = events.toList();
      state.registerTimeline(ordered.map((event) => event.eventId).toList());
      for (final event in ordered) {
        if (event.redacted) {
          state.onRedacted(event.eventId);
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
        state.onMessageArrived(
            eventId: event.eventId,
            order: state.orderFor(event.eventId),
            senderIsSelf: event.senderId == state.accountId,
            mentionedUserIds: targets);
      }
      if (before != state.encode()) {
        await save(room, shouldContinue: shouldContinue);
      }
    } on _MentionScanCanceled {
      // Revoked sessions do not publish or persist further mention updates.
    }
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

final class _MentionScanCanceled implements Exception {
  const _MentionScanCanceled();
}
