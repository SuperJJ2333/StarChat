import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class LocalHiddenEvents {
  Future<void> hide(String roomId, String eventId);
  bool isHidden(String roomId, String eventId);
}

abstract interface class LocalClearedHistory {
  Future<void> clearThrough(String roomId, DateTime cutoff);
  DateTime? clearedThrough(String roomId);
}

typedef LocalHistoryFilter = bool Function(String eventId, DateTime? timestamp);

abstract interface class LocalHistoryFilterSnapshots {
  LocalHistoryFilter readFilter(String roomId);
}

extension LocalHiddenEventsFiltering on LocalHiddenEvents {
  LocalHistoryFilter readFilter(String roomId) {
    final store = this;
    if (store is LocalHistoryFilterSnapshots) {
      return (store as LocalHistoryFilterSnapshots).readFilter(roomId);
    }
    return (id, timestamp) =>
        isEventHidden(roomId, id, eventTimestamp: timestamp);
  }

  bool isEventHidden(String roomId, String eventId,
      {DateTime? eventTimestamp}) {
    if (isHidden(roomId, eventId)) return true;
    final store = this;
    if (store is! LocalClearedHistory || eventTimestamp == null) return false;
    final cutoff = (store as LocalClearedHistory).clearedThrough(roomId);
    return cutoff != null && !eventTimestamp.isAfter(cutoff);
  }

  List<T> visibleItems<T>(
    String roomId,
    Iterable<T> items, {
    required String Function(T item) eventId,
    DateTime Function(T item)? eventTimestamp,
  }) {
    final hidden = readFilter(roomId);
    return items
        .where((item) => !hidden(eventId(item), eventTimestamp?.call(item)))
        .toList(growable: false);
  }
}

final class SharedPreferencesLocalHiddenEvents
    implements
        LocalHiddenEvents,
        LocalClearedHistory,
        LocalHistoryFilterSnapshots {
  const SharedPreferencesLocalHiddenEvents({
    required this.preferences,
    required this.accountId,
  });

  final SharedPreferences preferences;
  final String accountId;

  @override
  LocalHistoryFilter readFilter(String roomId) {
    final key = _key(roomId);
    final ids = preferences.getStringList(key)?.toSet() ?? const <String>{};
    final milliseconds = preferences.getInt('$key.cleared-through');
    final cutoff = milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
    return (id, timestamp) =>
        ids.contains(id) ||
        (cutoff != null &&
            timestamp != null &&
            !timestamp.isAfter(cutoff));
  }

  String _key(String roomId) {
    final scope = sha256.convert(utf8.encode('$accountId\u0000$roomId'));
    return 'changliao.hidden-events.v1.$scope';
  }

  @override
  DateTime? clearedThrough(String roomId) {
    final milliseconds = preferences.getInt('${_key(roomId)}.cleared-through');
    return milliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }

  @override
  Future<void> clearThrough(String roomId, DateTime cutoff) async {
    final previous = clearedThrough(roomId);
    if (previous != null && !cutoff.isAfter(previous)) return;
    final saved = await preferences.setInt(
        '${_key(roomId)}.cleared-through', cutoff.millisecondsSinceEpoch);
    if (!saved) throw StateError('Unable to save local history cutoff');
  }

  @override
  Future<void> hide(String roomId, String eventId) async {
    final key = _key(roomId);
    final ids = preferences.getStringList(key)?.toSet() ?? <String>{};
    ids.add(eventId);
    final stable = ids.toList(growable: false)..sort();
    await preferences.setStringList(key, stable);
  }

  @override
  bool isHidden(String roomId, String eventId) =>
      preferences.getStringList(_key(roomId))?.contains(eventId) ?? false;
}
