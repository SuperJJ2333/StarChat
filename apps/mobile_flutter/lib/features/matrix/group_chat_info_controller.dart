import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'conversation_preferences.dart';
import 'avatar_url_resolver.dart';

const groupChatAccountDataType = 'com.liuhetong.group_chat.settings.v1';

List<String> normalizeGroupAdminIds(
  Iterable<String> ids, {
  required String ownerId,
}) =>
    ids.where((id) => id != ownerId).toSet().take(3).toList(growable: false);

List<GroupChatMember> orderGroupMembers({
  required Iterable<GroupChatMember> members,
  required String ownerId,
  required Set<String> adminIds,
}) {
  final ordered = members.toList()
    ..sort((left, right) {
      int rank(GroupChatMember member) => member.matrixUserId == ownerId
          ? 0
          : adminIds.contains(member.matrixUserId)
              ? 1
              : 2;
      final rankDifference = rank(left).compareTo(rank(right));
      return rankDifference != 0
          ? rankDifference
          : left.displayName
              .toLowerCase()
              .compareTo(right.displayName.toLowerCase());
    });
  return ordered;
}

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
    this.avatarHeaders = const {},
    this.matrixAvatarUri,
    this.client,
    this.membership = Membership.join,
  });

  final String matrixUserId;
  final String displayName;
  final String? avatarUrl;
  final Map<String, String> avatarHeaders;
  final Uri? matrixAvatarUri;
  final Client? client;
  final Membership membership;
  bool get isJoined => membership == Membership.join;
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
    this.ownerId = '',
    this.adminIds = const [],
    this.qrJoinEnabled = true,
    this.joinApprovalRequired = false,
    this.onlyManagersCanRename = false,
    this.currentUserId,
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
  final String ownerId;
  final List<String> adminIds;
  final bool qrJoinEnabled;
  final bool joinApprovalRequired;
  final bool onlyManagersCanRename;
  final String? currentUserId;
  bool get isOwner => ownerId.isNotEmpty && ownerId == currentUserId;
  bool get isAdmin => adminIds.contains(currentUserId);
  bool get canManage => isOwner || isAdmin;

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
    String? ownerId,
    List<String>? adminIds,
    bool? qrJoinEnabled,
    bool? joinApprovalRequired,
    bool? onlyManagersCanRename,
    String? currentUserId,
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
        ownerId: ownerId ?? this.ownerId,
        adminIds: adminIds ?? this.adminIds,
        qrJoinEnabled: qrJoinEnabled ?? this.qrJoinEnabled,
        joinApprovalRequired: joinApprovalRequired ?? this.joinApprovalRequired,
        onlyManagersCanRename:
            onlyManagersCanRename ?? this.onlyManagersCanRename,
        currentUserId: currentUserId ?? this.currentUserId,
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
  Future<void> setGroupSetting(String key, Object value);
  Future<void> setAdminIds(List<String> matrixUserIds);
  Future<void> removeMembers(List<String> matrixUserIds);
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
    final localJoined = room.getParticipants([Membership.join]).length;
    final users = await room.requestParticipants([Membership.join]);
    final invited = await room.requestParticipants([Membership.invite]);
    debugPrint(
      '[GroupMembers] local_joined=$localJoined '
      'server_joined=${users.length} server_invited=${invited.length}',
    );
    final modern = room.roomAccountData[conversationPreferenceType]?.content;
    final settings =
        modern == null ? _settings : Map<String, Object?>.from(modern);
    _cachedSettings = settings;
    final followed = settings['followed_member_ids'];
    final storedOrder = settings['member_order_ids'];
    final allMembers = [...users, ...invited];
    final order = reconcileMemberOrder(
      storedOrder is List
          ? storedOrder.map((value) => value.toString())
          : const <String>[],
      allMembers.map((user) => user.id),
    );
    // State events can arrive before the membership endpoint's pagination.
    // Keep every joined/invited participant once, preserving the stored order.
    final userById = {for (final user in allMembers) user.id: user};
    final ownerId = settings['owner_id']?.toString().isNotEmpty == true
        ? settings['owner_id'].toString()
        : room.getState(EventTypes.RoomCreate)?.senderId ?? '';
    final adminIds = normalizeGroupAdminIds(
      settings['admin_ids'] is List
          ? (settings['admin_ids'] as List).map((value) => value.toString())
          : const <String>[],
      ownerId: ownerId,
    );
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
      ownerId: ownerId,
      adminIds: adminIds,
      qrJoinEnabled: settings['qr_join_enabled'] != false,
      joinApprovalRequired: settings['join_approval_required'] == true,
      onlyManagersCanRename: settings['only_managers_can_rename'] == true,
      currentUserId: room.client.userID,
      members: orderGroupMembers(members: [
        for (final user in orderedUsers) await _member(user),
      ], ownerId: ownerId, adminIds: adminIds.toSet()),
    );
  }

  Future<GroupChatMember> _member(User user) async {
    final avatar = MatrixAvatarUrlResolver.resolveImmediately(
      avatarUri: user.avatarUrl,
      homeserver: room.client.homeserver,
      accessToken: room.client.accessToken,
      size: 48,
    );
    return GroupChatMember(
      matrixUserId: user.id,
      displayName: user.calcDisplayname(),
      avatarUrl: avatar?.url,
      avatarHeaders: avatar?.headers ?? const {},
      matrixAvatarUri: user.avatarUrl,
      client: room.client,
      membership: user.membership,
    );
  }

  @override
  Future<void> invite(String matrixUserId) => room.invite(matrixUserId);

  @override
  Future<void> leave() => room.leave();

  @override
  Future<void> removeMembers(List<String> matrixUserIds) async {
    for (final userId in matrixUserIds) {
      await room.kick(userId);
    }
  }

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) => _writeSetting(
      'admin_ids',
      normalizeGroupAdminIds(matrixUserIds,
          ownerId: room.getState(EventTypes.RoomCreate)?.senderId ?? ''));

  @override
  Future<void> setGroupSetting(String key, Object value) =>
      _writeSetting(key, value);

  @override
  Future<void> rename(String name) async {
    await room.setName(name);
  }

  @override
  Future<void> setAnnouncement(String announcement) async {
    await room.setDescription(announcement);
    final version =
        ((_settings['announcement_version'] as num?)?.toInt() ?? 0) + 1;
    await _writeSetting('announcement_version', version);
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

  Future<void> setGroupSetting(String key, bool value) => _save(
        () => gateway.setGroupSetting(key, value),
        (snapshot) => switch (key) {
          'qr_join_enabled' => snapshot.copyWith(qrJoinEnabled: value),
          'join_approval_required' =>
            snapshot.copyWith(joinApprovalRequired: value),
          'only_managers_can_rename' =>
            snapshot.copyWith(onlyManagersCanRename: value),
          _ => snapshot,
        },
      );

  Future<void> removeMembers(List<String> ids) async {
    await gateway.removeMembers(ids);
    await load();
  }

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
