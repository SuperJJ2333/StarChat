import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../core/session_store.dart';
import 'mention_composer_model.dart';

final class RoomDraft {
  const RoomDraft(this.text, {this.tokens = const []});
  final String text;
  final List<MentionToken> tokens;

  Map<String, Object?> toJson() => {
        'text': text,
        'tokens': [
          for (final t in tokens)
            {
              'start': t.start,
              'end': t.end,
              'display': t.display,
              'userId': t.userId,
              'all': t.mentionAllUserIds
            }
        ]
      };

  static RoomDraft decode(String value) {
    final json = jsonDecode(value) as Map<String, dynamic>;
    final text = json['text'] as String;
    final tokens = <MentionToken>[];
    for (final item in (json['tokens'] as List? ?? const [])) {
      if (item is! Map ||
          item['start'] is! int ||
          item['end'] is! int ||
          item['display'] is! String ||
          item['userId'] is! String) {
        continue;
      }
      final start = item['start'] as int, end = item['end'] as int;
      if (start < 0 ||
          end <= start ||
          end > text.length ||
          text.substring(start, end) != '@${item['display']}') {
        continue;
      }
      tokens.add(MentionToken(
          start: start,
          end: end,
          display: item['display'],
          userId: item['userId'],
          mentionAllUserIds:
              (item['all'] as List?)?.whereType<String>().toList()));
    }
    return RoomDraft(text, tokens: List.unmodifiable(tokens));
  }
}

final class RoomDraftStore {
  RoomDraftStore(this.storage);
  final SecureKeyValueStore storage;
  static final shared = RoomDraftStore(FlutterSecureKeyValueStore());
  final _cache = <String, RoomDraft?>{};
  final _timers = <String, Timer>{};
  final _writes = <String, Future<void>>{};
  Object? lastError;
  static String key(String server, String account, String room) =>
      'room.draft.v1.${sha256.convert(utf8.encode(jsonEncode([
            server,
            account,
            room
          ])))}';

  void save(String key, RoomDraft draft) {
    // Snapshot metadata: the composer mutates its token list on the next edit.
    _cache[key] = draft.text.isEmpty
        ? null
        : RoomDraft.decode(jsonEncode(draft.toJson()));
    _timers.remove(key)?.cancel();
    _timers[key] =
        Timer(const Duration(milliseconds: 300), () => unawaited(flush(key)));
  }

  Future<void> flush(String key) async {
    _timers.remove(key)?.cancel();
    if (!_cache.containsKey(key)) return;
    final value = _cache[key];
    final previous = _writes[key] ?? Future<void>.value();
    final next = previous.then((_) async {
      try {
        if (value == null) {
          await storage.delete(key);
        } else {
          await storage.write(key, jsonEncode(value.toJson()));
        }
        lastError = null;
      } catch (error) {
        // Retain memory and retry on the next edit/background/room exit.
        lastError = error;
      }
    });
    _writes[key] = next;
    await next;
    if (identical(_writes[key], next)) _writes.remove(key);
  }

  Future<RoomDraft?> read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final value = await storage.read(key);
      // A save or send-clear during I/O is authoritative over the old read.
      if (_cache.containsKey(key)) return _cache[key];
      final draft = value == null ? null : RoomDraft.decode(value);
      return _cache[key] = draft?.text.isEmpty == true ? null : draft;
    } catch (error) {
      lastError = error;
      return _cache[key];
    }
  }
}
