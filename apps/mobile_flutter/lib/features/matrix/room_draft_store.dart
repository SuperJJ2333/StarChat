import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import '../../core/session_store.dart';
import 'mention_composer_model.dart';

final class RoomDraft {
  const RoomDraft(this.text, {this.tokens = const []});
  final String text;
  final List<MentionToken> tokens;

  /// Freeze only mutable mention metadata; String already has value semantics.
  RoomDraft snapshot() => RoomDraft(text,
      tokens: List<MentionToken>.unmodifiable([
        for (final token in tokens)
          if (token.start >= 0 &&
              token.end > token.start &&
              token.end <= text.length &&
              text.substring(token.start, token.end) == '@${token.display}')
            MentionToken(
              start: token.start,
              end: token.end,
              display: token.display,
              userId: token.userId,
              mentionAllUserIds: token.mentionAllUserIds == null
                  ? null
                  : List<String>.unmodifiable(token.mentionAllUserIds!),
            )
      ]));

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
    return RoomDraft(text, tokens: tokens).snapshot();
  }
}

final class RoomDraftStore {
  RoomDraftStore(this.storage);
  final SecureKeyValueStore storage;
  static final shared = RoomDraftStore(FlutterSecureKeyValueStore());

  /// BUG-20：会话列表草稿预览索引（进程内，roomId → 草稿正文的逐房间
  /// 通知器）。由房间页在保存草稿时登记；列表 tile 各自监听自己的通知器
  /// ——草稿更新只重建对应一个 tile，不重建整个列表（真机回归修订：
  /// 全列表 setState 在房间页覆盖期间反复触发导致明显卡顿与延迟）。
  /// 冷启动后需进入过会话才有值（存储层扫描列为后续优化）。
  final _previews = <String, ValueNotifier<String?>>{};

  ValueNotifier<String?> _notifierFor(String roomId) =>
      _previews.putIfAbsent(roomId, () => ValueNotifier<String?>(null));

  ValueListenable<String?> draftListenable(String roomId) =>
      _notifierFor(roomId);

  /// 当前有草稿的房间 ID 集合（会话排序上浮依据）。
  Set<String> get draftRoomIds => {
        for (final entry in _previews.entries)
          if (entry.value.value != null) entry.key,
      };

  /// 仅在「房间进入/离开草稿态」时递增（文本编辑不触发，避免整列表重建）。
  /// 会话列表据此重排：有草稿的会话上浮到置顶之下、普通会话之前。
  final ValueNotifier<int> draftMembershipRevision = ValueNotifier<int>(0);

  void recordDraftPreview(String roomId, String? text) {
    final next = (text == null || text.isEmpty) ? null : text;
    final notifier = _notifierFor(roomId);
    final hadDraft = notifier.value != null;
    final hasDraft = next != null;
    if (notifier.value == next) return;
    notifier.value = next;
    // 成员修订只在进入/离开草稿态时发——正文编辑由逐 tile 通知器消化，
    // 不触发会话列表重排。
    if (hadDraft != hasDraft) draftMembershipRevision.value++;
  }
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
    _cache[key] = draft.text.isEmpty ? null : draft.snapshot();
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
