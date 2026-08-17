import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class LocalHiddenEvents {
  Future<void> hide(String roomId, String eventId);
  bool isHidden(String roomId, String eventId);
}

extension LocalHiddenEventsFiltering on LocalHiddenEvents {
  List<T> visibleItems<T>(
    String roomId,
    Iterable<T> items, {
    required String Function(T item) eventId,
  }) =>
      items
          .where((item) => !isHidden(roomId, eventId(item)))
          .toList(growable: false);
}

final class SharedPreferencesLocalHiddenEvents implements LocalHiddenEvents {
  const SharedPreferencesLocalHiddenEvents({
    required this.preferences,
    required this.accountId,
  });

  final SharedPreferences preferences;
  final String accountId;

  String _key(String roomId) {
    final scope = sha256.convert(utf8.encode('$accountId\u0000$roomId'));
    return 'changliao.hidden-events.v1.$scope';
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
