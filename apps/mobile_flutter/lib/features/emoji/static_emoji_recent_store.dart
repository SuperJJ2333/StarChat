import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'fluent_vector_emoji_catalog.dart';

/// Device-only, account-scoped static emoji identifiers. Never stores drafts.
final class StaticEmojiRecentStore {
  StaticEmojiRecentStore({required this.accountId});

  final String accountId;
  static const limit = 16;
  static Future<void>? _pending;
  static final _allowed = vectorEmojis.map((emoji) => emoji.char).toSet();

  String get storageKey =>
      'chat.static_emoji_recents.v1.${base64Url.encode(utf8.encode(accountId))}';

  static List<String> normalize(Iterable<String> values) =>
      values.where(_allowed.contains).toSet().take(limit).toList();

  // Panels may close/reopen or coexist while preferences load. Serialize reads
  // and read-modify-writes across store instances so a rapid use is not lost.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final previous = _pending;
    final result = previous == null
        ? Future<T>.sync(operation)
        : previous.then((_) => operation());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _pending = tail;
    tail.then((_) {
      // Keep only in-flight work. A completed tail need not retain the prior
      // store/zone, and cannot clear a newer operation's serialization guard.
      if (identical(_pending, tail)) _pending = null;
    });
    return result;
  }

  Future<List<String>> load() => _enqueue(() async {
        if (accountId.isEmpty) return <String>[];
        final prefs = await SharedPreferences.getInstance();
        return normalize(prefs.getStringList(storageKey) ?? const []);
      });

  Future<void> record(String char) => _enqueue(() async {
        if (accountId.isEmpty || !_allowed.contains(char)) return;
        final prefs = await SharedPreferences.getInstance();
        final values = normalize([char, ...?prefs.getStringList(storageKey)]);
        await prefs.setStringList(storageKey, values);
      });
}
