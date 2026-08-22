import 'package:matrix/matrix.dart';

const conversationPreferenceType = 'com.liuhetong.conversation.settings.v2';

final class ConversationPreference {
  const ConversationPreference({
    this.muted = false,
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

  final bool muted;
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
      if (time != 0) return time;
    } else {
      final activity = b.lastActivity.compareTo(a.lastActivity);
      if (activity != 0) return activity;
    }
    return a.roomId.compareTo(b.roomId);
  });
  return result;
}

ConversationPreference preferenceForRoom(Room room) =>
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
