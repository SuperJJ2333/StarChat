import 'conversation_read_state.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matrix/matrix.dart';

const conversationPreferenceType = 'com.liuhetong.conversation.settings.v2';
const _knownPreferenceKeys = <String>{
  'muted',
  'attention',
  'pinned',
  'saved',
  'folded',
  'notify_mention_me',
  'notify_mention_all',
  'notify_announcement',
  'followed_member_ids',
  'member_order_ids',
  'pinned_at',
  'manual_unread',
  'hidden',
  'hidden_at',
};

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
    this.extraContent = const {},
  });

  factory ConversationPreference.fromContent(Map<String, Object?> content) {
    final followed = content['followed_member_ids'];
    final explicitMuteExceptions = content['mute_exceptions_explicit'] == true;
    return ConversationPreference(
      muted: content['muted'] == true,
      attention: content['attention'] == true,
      pinned: content['pinned'] == true,
      saved: content['saved'] == true,
      folded: content['folded'] == true,
      notifyMentionMe: content['muted'] == true
          ? explicitMuteExceptions && content['notify_mention_me'] == true
          : content['notify_mention_me'] != false,
      notifyMentionAll: content['muted'] == true
          ? explicitMuteExceptions && content['notify_mention_all'] == true
          : content['notify_mention_all'] != false,
      notifyAnnouncement: content['muted'] == true
          ? explicitMuteExceptions && content['notify_announcement'] == true
          : content['notify_announcement'] != false,
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
      extraContent: Map<String, Object?>.unmodifiable({
        for (final entry in content.entries)
          if (!_knownPreferenceKeys.contains(entry.key)) entry.key: entry.value,
      }),
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

  /// Preserve group metadata and newer account-data fields on old clients.
  final Map<String, Object?> extraContent;

  Map<String, Object?> toContent() => {
        ...extraContent,
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
        extraContent: extraContent,
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
      final push = decoded['__push_pending__'];
      if (push is Map) {
        for (final entry in push.entries) {
          if (entry.key is String && entry.value is bool) {
            pushPending[entry.key as String] = entry.value as bool;
          }
        }
      }
      final applied = decoded['__push_applied__'];
      if (applied is List) {
        pushApplied.addAll(applied.whereType<String>());
      }
      for (final entry in decoded.entries) {
        if (entry.key.startsWith('__push_')) continue;
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
  final pushPending = <String, bool>{};
  final pushApplied = <String>{};
  final sending = <String>{};
  final acknowledged = <String, ConversationPreference>{};
  Future<void> _lastPersistence = Future.value();
  Future<void> persist() {
    final encoded = jsonEncode({
      for (final entry in pending.entries) entry.key: entry.value.toContent(),
      '__push_pending__': pushPending,
      '__push_applied__': pushApplied.toList(),
    });
    final write = _lastPersistence.then((_) async {
      if (!await preferences.setString(key, encoded)) {
        throw StateError('无法保存会话设置');
      }
    });
    _lastPersistence = write.catchError((Object _) {});
    return write;
  }
}

Future<void> loadConversationPreferences(Client client) async {
  final userId = client.userID;
  ConversationReadState.shared().bindAccount(userId);
  if (userId == null) return;
  final key = 'conversation_preferences.v1.$userId';
  if (_localPreferences[client]?.key != key) {
    final preferences = await SharedPreferences.getInstance();
    if (client.userID != userId) return;
    _localPreferences[client] = _LocalConversationPreferences(preferences, key);
  }
  final store = _localPreferences[client]!;
  var migrated = false;
  for (final room in client.rooms) {
    final effective = store.pending[room.id] ?? remotePreferenceForRoom(room);
    if (effective.muted &&
        !store.pushApplied.contains(room.id) &&
        store.pushPending[room.id] != true) {
      store.pushPending[room.id] = true;
      migrated = true;
    } else if (!effective.muted &&
        (store.pushApplied.contains(room.id) ||
            store.pushPending.containsKey(room.id)) &&
        store.pushPending[room.id] != false) {
      store.pushPending[room.id] = false;
      migrated = true;
    }
  }
  if (migrated) await store.persist();
}

String conversationMutePushRuleId(String roomId) =>
    'com.liuhetong.mute.${base64Url.encode(utf8.encode(roomId)).replaceAll('=', '')}';

Future<void> _writeMutePushRule(
    Client client, String roomId, bool muted) async {
  final ruleId = conversationMutePushRuleId(roomId);
  if (muted) {
    // The SDK's Room.setPushRuleState reads a sync snapshot and may return
    // before any HTTP write. Write this app-owned rule directly instead.
    await client.setPushRule(
      PushRuleKind.override,
      ruleId,
      [PushRuleAction.dontNotify],
      conditions: [
        PushCondition(kind: 'event_match', key: 'room_id', pattern: roomId),
      ],
    );
  } else {
    try {
      await client.deletePushRule(PushRuleKind.override, ruleId);
    } on MatrixException catch (error) {
      if (error.errcode != 'M_NOT_FOUND') rethrow;
    }
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
  final previous = store.pending[room.id] ?? remotePreferenceForRoom(room);
  store.pending[room.id] = preference;
  if (preference.muted != previous.muted ||
      (preference.muted && !store.pushApplied.contains(room.id))) {
    store.pushPending[room.id] = preference.muted;
  }
  conversationPreferencesChanged.publish();
  await store.persist();
}

/// Called inside the Matrix client's managed lifecycle. Failed writes remain
/// durable and are retried on the next conversation snapshot/sync.
Future<void> flushConversationPreferences(Client client,
    {bool Function()? shouldContinue}) async {
  final store = _localPreferences[client];
  final userId = client.userID;
  if (store == null ||
      userId == null ||
      store.key != 'conversation_preferences.v1.$userId') {
    return;
  }
  bool active() =>
      client.userID == userId &&
      identical(_localPreferences[client], store) &&
      (shouldContinue?.call() ?? true);
  await Future.wait([
    for (final roomId in store.pending.keys.toList())
      () async {
        if (!store.sending.add(roomId)) return;
        try {
          while (store.pending[roomId] != null && active()) {
            final next = store.pending[roomId]!;
            if (!identical(store.acknowledged[roomId], next)) {
              await client.setAccountDataPerRoom(
                  userId, roomId, conversationPreferenceType, next.toContent());
              if (!active()) return;
              store.acknowledged[roomId] = next;
            }
            final muted = store.pushPending[roomId];
            if (muted != null && active()) {
              await _writeMutePushRule(client, roomId, muted);
              if (!active()) return;
              if (store.pushPending[roomId] == muted) {
                store.pushPending.remove(roomId);
                if (muted) {
                  store.pushApplied.add(roomId);
                } else {
                  store.pushApplied.remove(roomId);
                }
                await store.persist();
              }
            }
            if (identical(store.pending[roomId], next)) return;
          }
        } catch (_) {
          // Keep the local edit while offline; the next sync retries it.
        } finally {
          store.sending.remove(roomId);
        }
      }(),
  ]);
  // Existing muted server preferences may need a rule even without a local
  // account-data edit (for example after upgrading from an older app).
  await Future.wait([
    for (final entry in store.pushPending.entries.toList())
      if (!store.sending.contains(entry.key) &&
          !store.pending.containsKey(entry.key))
        () async {
          if (!store.sending.add(entry.key)) return;
          try {
            while (active()) {
              final muted = store.pushPending[entry.key];
              if (muted == null || !active()) return;
              await _writeMutePushRule(client, entry.key, muted);
              if (!active()) return;
              if (store.pushPending[entry.key] == muted) {
                store.pushPending.remove(entry.key);
                if (muted) {
                  store.pushApplied.add(entry.key);
                } else {
                  store.pushApplied.remove(entry.key);
                }
                await store.persist();
              }
            }
          } catch (_) {
            // Preserve the desired rule for the next online sync.
          } finally {
            store.sending.remove(entry.key);
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
