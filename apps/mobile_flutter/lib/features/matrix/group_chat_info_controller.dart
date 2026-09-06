import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'dart:async';

import 'conversation_preferences.dart';
import 'avatar_url_resolver.dart';
import 'group_room_authority.dart';
import 'group_announcement_service.dart';

const groupChatAccountDataType = 'com.liuhetong.group_chat.settings.v1';

String groupInfoDisplayName(String explicitName) {
  final normalized = explicitName.trim();
  return normalized.isEmpty ? '未命名' : normalized;
}

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
  attention,
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
    this.invitedMembers = const [],
    this.roomId,
    this.announcement = '',
    this.remark = '',
    this.muted = false,
    this.attention = false,
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

  /// 已真正 join 的成员（群人数唯一口径；Matrix 为权威来源）。
  final List<GroupChatMember> members;

  /// 待确认邀请（Membership.invite）：不计入群人数，不伪装成员。
  final List<GroupChatMember> invitedMembers;
  int get joinedCount => members.length;
  final bool muted;
  final bool attention;
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

  /// 群二维码签发/服务端协调所需的房间 ID（只读 opaque 标识）。
  final String? roomId;
  bool get isOwner => ownerId.isNotEmpty && ownerId == currentUserId;
  bool get isAdmin => adminIds.contains(currentUserId);
  bool get canManage => isOwner || isAdmin;

  GroupChatInfoSnapshot copyWith({
    String? name,
    String? announcement,
    String? remark,
    List<GroupChatMember>? members,
    List<GroupChatMember>? invitedMembers,
    bool? muted,
    bool? attention,
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
    String? roomId,
  }) =>
      GroupChatInfoSnapshot(
        name: name ?? this.name,
        announcement: announcement ?? this.announcement,
        remark: remark ?? this.remark,
        members: members ?? this.members,
        invitedMembers: invitedMembers ?? this.invitedMembers,
        muted: muted ?? this.muted,
        attention: attention ?? this.attention,
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
        roomId: roomId ?? this.roomId,
      );
}

abstract interface class GroupChatInfoGateway {
  String? get roomId;
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

abstract interface class GroupOwnershipGateway {
  Future<void> transferOwnership(String userId);
  Future<void> dissolve();
}

/// Successful local writes remain visible until their values arrive in sync.
final class GroupPreferenceOverlay {
  final _pending = <String, Object?>{};
  final _writeBaselines = <String, Object?>{};
  Object? _lastRemote;
  Object? get remoteIdentity => _lastRemote;
  void wrote(String key, Object? value, {Object? baseline}) {
    _pending[key] = value;
    _writeBaselines[key] = baseline ?? _lastRemote;
  }

  Map<String, Object?> read(Map<String, Object?> remote) {
    _pending.removeWhere((key, value) {
      if (identical(remote, _writeBaselines[key])) return false;
      final acknowledged = value is List && remote[key] is List
          ? listEquals(value, remote[key] as List)
          : remote[key] == value;
      if (acknowledged) _writeBaselines.remove(key);
      return acknowledged;
    });
    _lastRemote = remote;
    return {...remote, ..._pending};
  }
}

final class MatrixGroupChatInfoGateway
    implements GroupChatInfoGateway, GroupOwnershipGateway {
  MatrixGroupChatInfoGateway(this.room);

  final Room room;

  @override
  String? get roomId => room.id;
  final _preferenceOverlay = GroupPreferenceOverlay();
  Future<void> _preferenceWrites = Future.value();

  Map<String, Object?> get _settings => _preferenceOverlay.read(
        room.roomAccountData[conversationPreferenceType]?.content ??
            room.roomAccountData[groupChatAccountDataType]?.content ??
            const <String, Object?>{},
      );

  @override
  Future<GroupChatInfoSnapshot> load() async {
    await GroupRoomAuthority(room).refresh();
    final localJoined = room.getParticipants([Membership.join]).length;
    final users = await room.requestParticipants([Membership.join]);
    final invited = await room.requestParticipants([Membership.invite]);
    debugPrint(
      '[GroupMembers] local_joined=$localJoined '
      'server_joined=${users.length} server_invited=${invited.length}',
    );
    final settings = _settings;
    final followed = settings['followed_member_ids'];
    final storedOrder = settings['member_order_ids'];
    // BUG1：人数与成员列表只认真正 join；invite 是待确认邀请，绝不合并
    // 进 members（不再出现"人数增加了但对方没有真正进群"的假象）。
    final order = reconcileMemberOrder(
      storedOrder is List
          ? storedOrder.map((value) => value.toString())
          : const <String>[],
      users.map((user) => user.id),
    );
    final userById = {for (final user in users) user.id: user};
    final invitedOrder = reconcileMemberOrder(
      const <String>[],
      invited.map((user) => user.id),
    );
    final invitedById = {for (final user in invited) user.id: user};
    final authority = GroupRoomAuthority(room);
    final ownerId = authority.ownerId;
    final adminIds = users
        .where((user) =>
            user.id != ownerId && room.getPowerLevelByUserId(user.id) >= 50)
        .map((user) => user.id)
        .toList();
    final shared = room.getState(groupSettingsStateType)?.content ?? const {};
    final orderedUsers = [for (final id in order) userById[id]!];
    final activeIds = orderedUsers.map((user) => user.id).toSet();
    return GroupChatInfoSnapshot(
      name: room.name.trim(),
      announcement: await _announcementPreview(),
      remark: settings['remark']?.toString() ?? '',
      muted: settings['muted'] == true,
      attention: settings['attention'] == true,
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
      qrJoinEnabled: shared['qr_join_enabled'] != false,
      joinApprovalRequired: shared['join_approval_required'] == true,
      onlyManagersCanRename: authority.onlyManagersCanRename,
      currentUserId: room.client.userID,
      roomId: room.id,
      members: orderGroupMembers(members: [
        for (final user in orderedUsers) await _member(user),
      ], ownerId: ownerId, adminIds: adminIds.toSet()),
      invitedMembers: [
        for (final id in invitedOrder)
          if (invitedById[id] != null) await _member(invitedById[id]!),
      ],
    );
  }

  Future<String> _announcementPreview() async {
    try {
      return (await MatrixGroupAnnouncementService(room).load()).preview;
    } catch (_) {
      return '公告暂不可用，点击重试';
    }
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
    final authority = GroupRoomAuthority(room);
    await authority.refresh();
    authority.requireManager();
    for (final userId in matrixUserIds) {
      if (userId == authority.ownerId ||
          room.getPowerLevelByUserId(userId) >= room.ownPowerLevel) {
        throw StateError('不能移除群主或同级管理员');
      }
      await room.kick(userId);
    }
  }

  @override
  Future<void> setAdminIds(List<String> matrixUserIds) async {
    final authority = GroupRoomAuthority(room);
    await authority.refresh();
    authority.requireOwner();
    if (matrixUserIds.toSet().length > 3 ||
        matrixUserIds.contains(authority.ownerId)) {
      throw StateError('最多设置3位管理员');
    }
    final members = await room.requestParticipants([Membership.join]);
    if (matrixUserIds.any((id) => !members.any((user) => user.id == id))) {
      throw StateError('请选择已加入的成员');
    }
    await authority.protectState(protectRoles: true);
    final current = Map<String, dynamic>.from(
        room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
    final users = Map<String, dynamic>.from(current['users'] as Map? ?? {});
    for (final member in members) {
      if (member.id == authority.ownerId) continue;
      if (matrixUserIds.contains(member.id)) {
        users[member.id] = 50;
      } else if (room.getPowerLevelByUserId(member.id) >= 50) {
        users[member.id] = 0;
      }
    }
    await room.client.setRoomStateWithKey(
        room.id, EventTypes.RoomPowerLevels, '', {...current, 'users': users});
  }

  @override
  Future<void> transferOwnership(String userId) async {
    final authority = GroupRoomAuthority(room);
    await authority.refresh();
    authority.requireOwner();
    final members = await room.requestParticipants([Membership.join]);
    if (userId == authority.ownerId ||
        !members.any((user) => user.id == userId)) {
      throw StateError('请选择其他已加入的成员');
    }
    await authority.protectState(protectRoles: true);
    final current = Map<String, dynamic>.from(
        room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
    final users = Map<String, dynamic>.from(current['users'] as Map? ?? {});
    users[userId] = 100;
    users[authority.ownerId] = 0;
    await room.client.setRoomStateWithKey(
        room.id, EventTypes.RoomPowerLevels, '', {...current, 'users': users});
  }

  @override
  Future<void> dissolve() async {
    final authority = GroupRoomAuthority(room);
    await authority.refresh();
    authority.requireOwner();
    await setGroupSetting('qr_join_enabled', false);
    final members =
        await room.requestParticipants([Membership.join, Membership.invite]);
    // Stop on failure: never report dissolution after a partial removal.
    for (final member in members) {
      if (member.id != authority.ownerId) await room.kick(member.id);
    }
    await room.leave();
  }

  @override
  Future<void> setGroupSetting(String key, Object value) async {
    final authority = GroupRoomAuthority(room);
    await authority.refresh();
    authority.requireManager();
    if (!{
          'qr_join_enabled',
          'join_approval_required',
          'only_managers_can_rename'
        }.contains(key) ||
        value is! bool) {
      throw ArgumentError('不支持的群设置');
    }
    await authority.protectState();
    if (key == 'only_managers_can_rename') {
      final current = Map<String, dynamic>.from(
          room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
      final events = Map<String, dynamic>.from(current['events'] as Map? ?? {});
      events[EventTypes.RoomName] = value ? 50 : 0;
      await room.client.setRoomStateWithKey(room.id, EventTypes.RoomPowerLevels,
          '', {...current, 'events': events});
    } else {
      await room.client.setRoomStateWithKey(room.id, groupSettingsStateType, '',
          {...?room.getState(groupSettingsStateType)?.content, key: value});
    }
  }

  @override
  Future<void> rename(String name) async {
    if (!room.canChangeStateEvent(EventTypes.RoomName)) {
      throw StateError('没有修改群名权限');
    }
    await room.setName(name);
  }

  @override
  Future<void> setAnnouncement(String announcement) async {
    await MatrixGroupAnnouncementService(room)
        .save(GroupAnnouncement([AnnouncementBlock.text(announcement)]));
  }

  @override
  Future<void> setPreference(
    GroupChatPreference preference,
    bool value,
  ) async {
    await _writeSetting(
      switch (preference) {
        GroupChatPreference.muted => 'muted',
        GroupChatPreference.attention => 'attention',
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

  Future<void> _writeSetting(String key, Object value) {
    final operation = _preferenceWrites.then((_) async {
      final userId = room.client.userID;
      if (userId == null) throw StateError('Matrix 账号尚未登录');
      final next = {..._settings, key: value};
      final baseline = _preferenceOverlay.remoteIdentity;
      await room.client.setAccountDataPerRoom(
          userId, room.id, conversationPreferenceType, next);
      _preferenceOverlay.wrote(key, value, baseline: baseline);
    });
    _preferenceWrites = operation.catchError((Object _) {});
    return operation;
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

  String get title => '聊天信息(${snapshot?.joinedCount ?? 0})';
}

/// 服务端自动入群结果（/groups/auto-join 响应分桶）。
final class GroupAutoJoinOutcome {
  const GroupAutoJoinOutcome({
    this.joinedUserIds = const [],
    this.pendingUserIds = const [],
    this.failed = const [],
  });

  factory GroupAutoJoinOutcome.fromJson(Map<String, dynamic> json) =>
      GroupAutoJoinOutcome(
        joinedUserIds: (json['joined_user_ids'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        pendingUserIds: (json['pending_user_ids'] as List? ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        failed: (json['failed'] as List? ?? const [])
            .whereType<Map>()
            .map((entry) => entry['user_id']?.toString() ?? '')
            .where((id) => id.isNotEmpty)
            .toList(growable: false),
      );

  final List<String> joinedUserIds;
  final List<String> pendingUserIds;
  final List<String> failed;
  bool get hasFailures => failed.isNotEmpty;
}

final class GroupChatInfoController extends ChangeNotifier {
  GroupChatInfoController(this.gateway, {this.serverAutoJoin});

  final GroupChatInfoGateway gateway;

  /// 服务端自动入群（业务 id 列表 → /groups/auto-join）。null = 未接线
  /// （仅本地 Matrix invite，与旧行为兼容）。
  final Future<GroupAutoJoinOutcome?> Function(
      String roomId, List<String> inviteeUserIds)? serverAutoJoin;
  GroupChatInfoState state = const GroupChatInfoState();
  StreamSubscription<SyncUpdate>? _membershipSubscription;

  /// Binds Matrix room updates so membership changes refresh this controller
  /// while the chat-info route stays open.
  void bindMembershipChanges(Stream<SyncUpdate> updates,
      {required String roomId}) {
    _membershipSubscription?.cancel();
    _membershipSubscription = updates
        .where((update) => update.rooms?.join?.containsKey(roomId) == true)
        .listen((_) {
      if (state.status != GroupChatInfoStatus.loading) unawaited(load());
    });
  }

  @override
  void dispose() {
    _membershipSubscription?.cancel();
    super.dispose();
  }

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
        () {
          _requireManager();
          return gateway.setAnnouncement(value);
        },
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
          GroupChatPreference.attention => snapshot.copyWith(attention: value),
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
        () {
          _requireManager();
          return gateway.setGroupSetting(key, value);
        },
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
    try {
      _requireManager();
      await gateway.removeMembers(ids);
      await load();
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: state.snapshot,
        message: '移除群成员失败，请检查权限和网络',
      ));
    }
  }

  void _requireManager({bool ownerOnly = false}) {
    final snapshot = state.snapshot;
    if (snapshot == null ||
        (ownerOnly ? !snapshot.isOwner : !snapshot.canManage)) {
      throw StateError('没有群管理权限');
    }
  }

  Future<void> setAdminIds(List<String> ids) => _save(() {
        _requireManager(ownerOnly: true);
        return gateway.setAdminIds(ids);
      }, (snapshot) => snapshot.copyWith(adminIds: ids));

  Future<void> transferOwnership(String id) => _save(() {
        _requireManager(ownerOnly: true);
        return (gateway as GroupOwnershipGateway).transferOwnership(id);
      }, (snapshot) => snapshot.copyWith(ownerId: id));

  Future<bool> dissolve() async {
    if (state.status == GroupChatInfoStatus.saving) return false;
    try {
      _requireManager(ownerOnly: true);
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.saving, snapshot: state.snapshot));
      await (gateway as GroupOwnershipGateway).dissolve();
      return true;
    } catch (_) {
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.failed,
          snapshot: state.snapshot,
          message: '解散群聊失败，请检查权限和网络后重试'));
      return false;
    }
  }

  /// Replaces the in-memory member snapshot after a Matrix membership event.
  /// The page remains mounted, so the title and grid update immediately.
  void replaceMembers(Iterable<GroupChatMember> members) {
    final snapshot = state.snapshot;
    if (snapshot == null) return;
    final ordered = orderGroupMembers(
      members: members,
      ownerId: snapshot.ownerId,
      adminIds: snapshot.adminIds.toSet(),
    );
    final ids = ordered.map((member) => member.matrixUserId).toSet();
    _set(GroupChatInfoState(
      status: GroupChatInfoStatus.ready,
      snapshot: snapshot.copyWith(
        members: ordered,
        followedMemberIds:
            snapshot.followedMemberIds.where(ids.contains).toList(),
      ),
    ));
  }

  Future<void> invite(String matrixUserId, {String? businessUserId}) async {
    try {
      // 第一步：Matrix invite（成员关系权威来源，Matrix 鉴权邀请权限）。
      await gateway.invite(matrixUserId);
    } catch (_) {
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: state.snapshot,
        message: '添加群成员失败，请检查权限和网络',
      ));
      return;
    }
    // 第二步：服务端对开启"自动允许加入群聊"的好友执行授权代加入；
    // 失败不影响 invite 本身（邀请仍然成立，等待对方确认）。
    var joinMessage = '已发送邀请';
    final autoJoin = serverAutoJoin;
    if (businessUserId != null && autoJoin != null) {
      try {
        final outcome = await autoJoin(gateway.roomId ?? '', [businessUserId]);
        if (outcome == null) {
          joinMessage = '已发送邀请，等待对方确认';
        } else if (outcome.hasFailures) {
          joinMessage = '邀请已发送；部分成员需等待对方确认加入';
        } else if (outcome.joinedUserIds.isNotEmpty) {
          joinMessage = '对方已加入群聊';
        } else {
          joinMessage = '已发送邀请，等待对方确认';
        }
      } catch (_) {
        joinMessage = '邀请已发送；自动加入暂不可用，等待对方确认';
      }
    }
    try {
      await load();
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.ready,
        snapshot: state.snapshot,
        message: joinMessage,
      ));
    } catch (_) {
      // 刷新失败不回滚邀请；下次进入/成员事件会重新加载。
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
        snapshot: gateway is MatrixGroupChatInfoGateway
            ? await gateway.load()
            : update(snapshot),
      ));
    } catch (_) {
      var refreshed = snapshot;
      if (gateway is MatrixGroupChatInfoGateway) {
        try {
          refreshed = await gateway.load();
        } catch (_) {/* Keep the last verified snapshot. */}
      }
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.failed,
        snapshot: refreshed,
        message: '保存失败，请检查权限和网络',
      ));
    }
  }

  void _set(GroupChatInfoState next) {
    state = next;
    notifyListeners();
  }
}
