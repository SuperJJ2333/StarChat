import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'conversation_preferences.dart';

const groupChatAccountDataType = 'com.liuhetong.group_chat.settings.v1';

enum GroupChatPreference {
  muted,
  pinned,
  saved,
  folded,
  notifyMentionMe,
  notifyMentionAll,
  notifyAnnouncement,
}

final class GroupChatMember {
  const GroupChatMember({
    required this.matrixUserId,
    required this.displayName,
    this.avatarUrl,
  });

  final String matrixUserId;
  final String displayName;
  final String? avatarUrl;
}

final class GroupChatInfoSnapshot {
  const GroupChatInfoSnapshot({
    required this.name,
    required this.members,
    this.announcement = '',
    this.remark = '',
    this.muted = false,
    this.pinned = false,
    this.saved = false,
    this.folded = false,
    this.notifyMentionMe = true,
    this.notifyMentionAll = true,
    this.notifyAnnouncement = true,
    this.followedMemberIds = const [],
  });

  final String name;
  final String announcement;
  final String remark;
  final List<GroupChatMember> members;
  final bool muted;
  final bool pinned;
  final bool saved;
  final bool folded;
  final bool notifyMentionMe;
  final bool notifyMentionAll;
  final bool notifyAnnouncement;
  final List<String> followedMemberIds;

  GroupChatInfoSnapshot copyWith({
    String? name,
    String? announcement,
    String? remark,
    List<GroupChatMember>? members,
    bool? muted,
    bool? pinned,
    bool? saved,
    bool? folded,
    bool? notifyMentionMe,
    bool? notifyMentionAll,
    bool? notifyAnnouncement,
    List<String>? followedMemberIds,
  }) =>
      GroupChatInfoSnapshot(
        name: name ?? this.name,
        announcement: announcement ?? this.announcement,
        remark: remark ?? this.remark,
        members: members ?? this.members,
        muted: muted ?? this.muted,
        pinned: pinned ?? this.pinned,
        saved: saved ?? this.saved,
        folded: folded ?? this.folded,
        notifyMentionMe: notifyMentionMe ?? this.notifyMentionMe,
        notifyMentionAll: notifyMentionAll ?? this.notifyMentionAll,
        notifyAnnouncement: notifyAnnouncement ?? this.notifyAnnouncement,
        followedMemberIds: followedMemberIds ?? this.followedMemberIds,
      );
}

abstract interface class GroupChatInfoGateway {
  Future<GroupChatInfoSnapshot> load();
  Future<void> rename(String name);
  Future<void> setAnnouncement(String announcement);
  Future<void> setRemark(String remark);
  Future<void> setPreference(GroupChatPreference preference, bool value);
  Future<void> setFollowedMemberIds(List<String> matrixUserIds);
  Future<void> invite(String matrixUserId);
  Future<void> leave();
}

final class MatrixGroupChatInfoGateway implements GroupChatInfoGateway {
  MatrixGroupChatInfoGateway(this.room);

  final Room room;
  Map<String, Object?>? _cachedSettings;

  Map<String, Object?> get _settings =>
      _cachedSettings ??= Map<String, Object?>.from(
        room.roomAccountData[groupChatAccountDataType]?.content ?? const {},
      );

  @override
  Future<GroupChatInfoSnapshot> load() async {
    final users = await room.requestParticipants([Membership.join]);
    final modern = room.roomAccountData[conversationPreferenceType]?.content;
    final settings =
        modern == null ? _settings : Map<String, Object?>.from(modern);
    _cachedSettings = settings;
    final followed = settings['followed_member_ids'];
    final storedOrder = settings['member_order_ids'];
    final order = reconcileMemberOrder(
      storedOrder is List
          ? storedOrder.map((value) => value.toString())
          : const <String>[],
      users.map((user) => user.id),
    );
    final userById = {for (final user in users) user.id: user};
    final orderedUsers = [for (final id in order) userById[id]!];
    final activeIds = orderedUsers.map((user) => user.id).toSet();
    return GroupChatInfoSnapshot(
      name: room.getLocalizedDisplayname(),
      announcement: room.topic,
      remark: settings['remark']?.toString() ?? '',
      muted: settings['muted'] == true,
      pinned: settings['pinned'] == true,
      saved: settings['saved'] == true,
      folded: settings['folded'] == true,
      notifyMentionMe: settings['notify_mention_me'] != false,
      notifyMentionAll: settings['notify_mention_all'] != false,
      notifyAnnouncement: settings['notify_announcement'] != false,
      followedMemberIds: followed is List
          ? followed
              .map((value) => value.toString())
              .where(activeIds.contains)
              .take(4)
              .toList()
          : const [],
      members: [
        for (final user in orderedUsers)
          GroupChatMember(
            matrixUserId: user.id,
            displayName: user.calcDisplayname(),
            avatarUrl: switch (user.avatarUrl) {
              final uri? when uri.scheme == 'http' || uri.scheme == 'https' =>
                uri.toString(),
              _ => null,
            },
          ),
      ],
    );
  }

  @override
  Future<void> invite(String matrixUserId) => room.invite(matrixUserId);

  @override
  Future<void> leave() => room.leave();

  @override
  Future<void> rename(String name) async {
    await room.setName(name);
  }

  @override
  Future<void> setAnnouncement(String announcement) async {
    await room.setDescription(announcement);
  }

  @override
  Future<void> setPreference(
    GroupChatPreference preference,
    bool value,
  ) async {
    await _writeSetting(
      switch (preference) {
        GroupChatPreference.muted => 'muted',
        GroupChatPreference.pinned => 'pinned',
        GroupChatPreference.saved => 'saved',
        GroupChatPreference.folded => 'folded',
        GroupChatPreference.notifyMentionMe => 'notify_mention_me',
        GroupChatPreference.notifyMentionAll => 'notify_mention_all',
        GroupChatPreference.notifyAnnouncement => 'notify_announcement',
      },
      value,
    );
    if (preference == GroupChatPreference.pinned) {
      await _writeSetting(
        'pinned_at',
        value ? DateTime.now().toUtc().toIso8601String() : '',
      );
    }
  }

  @override
  Future<void> setFollowedMemberIds(List<String> matrixUserIds) =>
      _writeSetting('followed_member_ids', matrixUserIds.take(4).toList());

  @override
  Future<void> setRemark(String remark) => _writeSetting('remark', remark);

  Future<void> _writeSetting(String key, Object value) async {
    final userId = room.client.userID;
    if (userId == null) throw StateError('Matrix 账号尚未登录');
    final next = {..._settings, key: value};
    await room.client.setAccountDataPerRoom(
      userId,
      room.id,
      conversationPreferenceType,
      next,
    );
    _cachedSettings = next;
  }
}

enum GroupChatInfoStatus { idle, loading, ready, saving, failed }

final class GroupChatInfoState {
  const GroupChatInfoState({
    this.status = GroupChatInfoStatus.idle,
    this.snapshot,
    this.message,
  });

  final GroupChatInfoStatus status;
  final GroupChatInfoSnapshot? snapshot;
  final String? message;

  String get title => '聊天信息(${snapshot?.members.length ?? 0})';
}

final class GroupChatInfoController extends ChangeNotifier {
  GroupChatInfoController(this.gateway);

  final GroupChatInfoGateway gateway;
  GroupChatInfoState state = const GroupChatInfoState();

  Future<void> load() async {
    _set(GroupChatInfoState(
      status: GroupChatInfoStatus.loading,
      snapshot: state.snapshot,
    ));
    try {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.ready,
        snapshot: await gateway.load(),
      ));
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: state.snapshot,
        message: '群聊信息加载失败，请重试',
      ));
    }
  }

  Future<void> rename(String value) => _save(
        () => gateway.rename(value),
        (snapshot) => snapshot.copyWith(name: value),
      );

  Future<void> setAnnouncement(String value) => _save(
        () => gateway.setAnnouncement(value),
        (snapshot) => snapshot.copyWith(announcement: value),
      );

  Future<void> setRemark(String value) => _save(
        () => gateway.setRemark(value),
        (snapshot) => snapshot.copyWith(remark: value),
      );

  Future<void> setPreference(GroupChatPreference preference, bool value) =>
      _save(
        () => gateway.setPreference(preference, value),
        (snapshot) => switch (preference) {
          GroupChatPreference.muted => snapshot.copyWith(muted: value),
          GroupChatPreference.pinned => snapshot.copyWith(pinned: value),
          GroupChatPreference.saved => snapshot.copyWith(saved: value),
          GroupChatPreference.folded => snapshot.copyWith(folded: value),
          GroupChatPreference.notifyMentionMe =>
            snapshot.copyWith(notifyMentionMe: value),
          GroupChatPreference.notifyMentionAll =>
            snapshot.copyWith(notifyMentionAll: value),
          GroupChatPreference.notifyAnnouncement =>
            snapshot.copyWith(notifyAnnouncement: value),
        },
      );

  Future<void> setFollowedMemberIds(List<String> matrixUserIds) => _save(
        () => gateway.setFollowedMemberIds(matrixUserIds),
        (snapshot) => snapshot.copyWith(
          followedMemberIds: matrixUserIds
              .where((id) =>
                  snapshot.members.any((member) => member.matrixUserId == id))
              .take(4)
              .toList(),
        ),
      );

  Future<void> invite(String matrixUserId) async {
    try {
      await gateway.invite(matrixUserId);
      await load();
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: state.snapshot,
        message: '添加群成员失败，请检查权限和网络',
      ));
    }
  }

  Future<bool> leave() async {
    try {
      await gateway.leave();
      return true;
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: state.snapshot,
        message: '退出群聊失败，请重试',
      ));
      return false;
    }
  }

  Future<void> _save(
    Future<void> Function() operation,
    GroupChatInfoSnapshot Function(GroupChatInfoSnapshot snapshot) update,
  ) async {
    final snapshot = state.snapshot;
    if (snapshot == null || state.status == GroupChatInfoStatus.saving) return;
    _set(GroupChatInfoState(
      status: GroupChatInfoStatus.saving,
      snapshot: snapshot,
    ));
    try {
      await operation();
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.ready,
        snapshot: update(snapshot),
      ));
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: snapshot,
        message: '保存失败，请检查权限和网络',
      ));
    }
  }

  void _set(GroupChatInfoState next) {
    state = next;
    notifyListeners();
  }
}
