import 'conversation_read_state.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart';

const conversationPreferenceType = 'com.liuhetong.conversation.settings.v2';

final class ConversationPreference {
  const ConversationPreference({
    this.muted = false,
    this.attention = false,
    this.pinned = false,
    this.saved = false,
    this.folded = false,
    this.notifyMentionMe = true,
    this.notifyMentionAll = true,
    this.notifyAnnouncement = true,
    this.followedMemberIds = const [],
    this.memberOrderIds = const [],
    this.pinnedAt,
    this.manualUnread = false,
    this.hidden = false,
    this.hiddenAt,
  });

  factory ConversationPreference.fromContent(Map<String, Object?> content) {
    final followed = content['followed_member_ids'];
    return ConversationPreference(
      muted: content['muted'] == true,
      attention: content['attention'] == true,
      pinned: content['pinned'] == true,
      saved: content['saved'] == true,
      folded: content['folded'] == true,
      notifyMentionMe: content['notify_mention_me'] != false,
      notifyMentionAll: content['notify_mention_all'] != false,
      notifyAnnouncement: content['notify_announcement'] != false,
      followedMemberIds: followed is List
          ? followed.map((value) => value.toString()).take(4).toList()
          : const [],
      memberOrderIds: content['member_order_ids'] is List
          ? (content['member_order_ids'] as List)
              .map((value) => value.toString())
              .toList()
          : const [],
      pinnedAt: DateTime.tryParse(content['pinned_at']?.toString() ?? ''),
      manualUnread: content['manual_unread'] == true,
      hidden: content['hidden'] == true,
      hiddenAt: DateTime.tryParse(content['hidden_at']?.toString() ?? ''),
    );
  }

  /// 会话通知三态（PRD §44）：默认 / 静音（muted） / 特别关注（attention）。
  /// attention 与 muted 互斥：置 attention 时写端须清 muted。
  final bool muted;
  final bool attention;
  final bool pinned;
  final bool saved;
  final bool folded;
  final bool notifyMentionMe;
  final bool notifyMentionAll;
  final bool notifyAnnouncement;
  final List<String> followedMemberIds;
  final List<String> memberOrderIds;
  final DateTime? pinnedAt;
  final bool manualUnread;
  final bool hidden;
  final DateTime? hiddenAt;

  Map<String, Object?> toContent() => {
        'muted': muted,
        'attention': attention,
        'pinned': pinned,
        'saved': saved,
        'folded': folded,
        'notify_mention_me': notifyMentionMe,
        'notify_mention_all': notifyMentionAll,
        'notify_announcement': notifyAnnouncement,
        'followed_member_ids': followedMemberIds.take(4).toList(),
        'member_order_ids': memberOrderIds,
        if (pinnedAt != null) 'pinned_at': pinnedAt!.toUtc().toIso8601String(),
        'manual_unread': manualUnread,
        'hidden': hidden,
        if (hiddenAt != null) 'hidden_at': hiddenAt!.toUtc().toIso8601String(),
      };

  ConversationPreference copyWith({
    bool? muted,
    bool? attention,
    bool? pinned,
    bool? saved,
    bool? folded,
    bool? notifyMentionMe,
    bool? notifyMentionAll,
    bool? notifyAnnouncement,
    List<String>? followedMemberIds,
    List<String>? memberOrderIds,
    DateTime? pinnedAt,
    bool clearPinnedAt = false,
    bool? manualUnread,
    bool? hidden,
    DateTime? hiddenAt,
    bool clearHiddenAt = false,
  }) =>
      ConversationPreference(
        muted: muted ?? this.muted,
        attention: attention ?? this.attention,
        pinned: pinned ?? this.pinned,
        saved: saved ?? this.saved,
        folded: folded ?? this.folded,
        notifyMentionMe: notifyMentionMe ?? this.notifyMentionMe,
        notifyMentionAll: notifyMentionAll ?? this.notifyMentionAll,
        notifyAnnouncement: notifyAnnouncement ?? this.notifyAnnouncement,
        followedMemberIds:
            (followedMemberIds ?? this.followedMemberIds).take(4).toList(),
        memberOrderIds: memberOrderIds ?? this.memberOrderIds,
        pinnedAt: clearPinnedAt ? null : (pinnedAt ?? this.pinnedAt),
        manualUnread: manualUnread ?? this.manualUnread,
        hidden: hidden ?? this.hidden,
        hiddenAt: clearHiddenAt ? null : (hiddenAt ?? this.hiddenAt),
      );
}

ConversationPreference markUnread(ConversationPreference preference) =>
    preference.copyWith(manualUnread: true);

ConversationPreference clearUnreadOnOpen(ConversationPreference preference) =>
    preference.copyWith(manualUnread: false);

ConversationPreference hideConversation(
  ConversationPreference preference,
  DateTime hiddenAt,
) =>
    preference.copyWith(hidden: true, hiddenAt: hiddenAt);

bool shouldRestoreHidden(
  ConversationPreference preference, {
  required DateTime eventAt,
  required bool isIncoming,
}) =>
    preference.hidden &&
    isIncoming &&
    (preference.hiddenAt == null || eventAt.isAfter(preference.hiddenAt!));

ConversationPreference restoreForIncomingEvent(
  ConversationPreference preference, {
  required DateTime eventAt,
  required bool isIncoming,
}) =>
    shouldRestoreHidden(preference, eventAt: eventAt, isIncoming: isIncoming)
        ? preference.copyWith(hidden: false, clearHiddenAt: true)
        : preference;

List<String> reconcileMemberOrder(
  Iterable<String> previous,
  Iterable<String> joined,
) {
  final active = joined.toSet();
  final result = previous.where(active.contains).toList();
  final known = result.toSet();
  for (final id in joined) {
    if (known.add(id)) result.add(id);
  }
  return result;
}

final class ConversationProjection {
  const ConversationProjection({
    required this.roomId,
    required this.isGroup,
    required this.lastActivity,
    this.preference = const ConversationPreference(),
  });
  final String roomId;
  final bool isGroup;
  final DateTime lastActivity;
  final ConversationPreference preference;
}

List<ConversationProjection> orderConversations(
  Iterable<ConversationProjection> source,
) {
  final result = source.toList();
  result.sort((a, b) {
    final aPinned = a.preference.pinned;
    final bPinned = b.preference.pinned;
    if (aPinned != bPinned) return aPinned ? -1 : 1;
    if (aPinned) {
      final time = (a.preference.pinnedAt ??
              DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(
              b.preference.pinnedAt ?? DateTime.fromMillisecondsSinceEpoch(0));
      if (time != 0) return -time;
    } else {
      final activity = b.lastActivity.compareTo(a.lastActivity);
      if (activity != 0) return activity;
    }
    return a.roomId.compareTo(b.roomId);
  });
  return result;
}

ConversationPreference remotePreferenceForRoom(Room room) =>
    ConversationPreference.fromContent(Map<String, Object?>.from(
      room.roomAccountData[conversationPreferenceType]?.content ??
          room.roomAccountData['com.liuhetong.group_chat.settings.v1']
              ?.content ??
          const {},
    ));

Future<void> writeConversationPreference(
  Room room,
  ConversationPreference preference,
) async {
  final userId = room.client.userID;
  if (userId == null) throw StateError('Matrix 账号尚未登录');
  await room.client.setAccountDataPerRoom(
    userId,
    room.id,
    conversationPreferenceType,
    preference.toContent(),
  );
}

/// Per-client cache, with durable account-scoped pending preferences. A sync
/// response cannot replace a local edit until it contains that edit.
final _localPreferences = Expando<_LocalConversationPreferences>();
final conversationPreferencesChanged = ConversationPreferenceChanges();

final class ConversationPreferenceChanges extends ChangeNotifier {
  void publish() => notifyListeners();
}

final class _LocalConversationPreferences {
  _LocalConversationPreferences(this.preferences, this.key) {
    final encoded = preferences.getString(key);
    if (encoded == null) return;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return;
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        pending[entry.key] = ConversationPreference.fromContent(
            Map<String, Object?>.from(entry.value as Map));
      }
    } on FormatException {
      // A corrupt device cache must not hide server-backed conversations.
    }
  }
  final SharedPreferences preferences;
  final String key;
  final pending = <String, ConversationPreference>{};
  final sending = <String>{};
  final acknowledged = <String, ConversationPreference>{};
  Future<void> persist() async {
    if (!await preferences.setString(
        key,
        jsonEncode({
          for (final entry in pending.entries)
            entry.key: entry.value.toContent(),
        }))) {
      throw StateError('无法保存会话设置');
    }
  }
}

Future<void> loadConversationPreferences(Client client) async {
  ConversationReadState.shared().bindAccount(client.userID);
  if (client.userID == null) return;
  if (_localPreferences[client] == null) {
    final preferences = await SharedPreferences.getInstance();
    _localPreferences[client] ??= _LocalConversationPreferences(
        preferences, 'conversation_preferences.v1.${client.userID}');
  }
}

Future<void> reconcileConversationPreferences(Client client) async {
  await loadConversationPreferences(client);
  final store = _localPreferences[client];
  if (store == null) return;
  var changed = false;
  for (final room in client.rooms) {
    final pending = store.pending[room.id];
    if (pending != null &&
        identical(store.acknowledged[room.id], pending) &&
        jsonEncode(pending.toContent()) ==
            jsonEncode(remotePreferenceForRoom(room).toContent())) {
      store.pending.remove(room.id);
      store.acknowledged.remove(room.id);
      changed = true;
    }
  }
  if (changed) await store.persist();
}

ConversationPreference preferenceForRoom(Room room) =>
    _localPreferences[room.client]?.pending[room.id] ??
    remotePreferenceForRoom(room);

Future<void> saveLocalConversationPreference(
    Room room, ConversationPreference preference) async {
  await loadConversationPreferences(room.client);
  final store = _localPreferences[room.client];
  if (store == null) throw StateError('Matrix 账号尚未登录');
  store.pending[room.id] = preference;
  conversationPreferencesChanged.publish();
  await store.persist();
}

/// Called inside the Matrix client's managed lifecycle. Failed writes remain
/// durable and are retried on the next conversation snapshot/sync.
Future<void> flushConversationPreferences(Client client,
    {bool Function()? shouldContinue}) async {
  final store = _localPreferences[client];
  final userId = client.userID;
  if (store == null || userId == null) return;
  await Future.wait([
    for (final roomId in store.pending.keys.toList())
      () async {
        if (!store.sending.add(roomId)) return;
        try {
          while (store.pending[roomId] != null &&
              (shouldContinue?.call() ?? true)) {
            final next = store.pending[roomId]!;
            if (identical(store.acknowledged[roomId], next)) return;
            await client.setAccountDataPerRoom(
                userId, roomId, conversationPreferenceType, next.toContent());
            store.acknowledged[roomId] = next;
          }
        } catch (_) {
          // Keep the local edit while offline; the next sync retries it.
        } finally {
          store.sending.remove(roomId);
        }
      }(),
  ]);
}

Future<void> clearLocalConversationPreferences(
    String? accountId, Client? client) async {
  if (accountId == null) return;
  final preferences = await SharedPreferences.getInstance();
  if (!await preferences.remove('conversation_preferences.v1.$accountId')) {
    throw StateError('无法删除会话设置');
  }
  if (client != null) _localPreferences[client] = null;
}
