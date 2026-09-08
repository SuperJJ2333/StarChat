import 'package:flutter/foundation.dart';
import 'dart:async';

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

/// App-owned membership DTO, deliberately independent from Matrix SDK enums.
enum GroupMemberMembership { joined, invited }

final class GroupChatMember {
  const GroupChatMember({
    required this.matrixUserId,
    required this.displayName,
    this.avatarUrl,
    this.avatarHeaders = const {},
    this.matrixAvatarUri,
    this.membership = GroupMemberMembership.joined,
  });

  final String matrixUserId;
  final String displayName;
  final String? avatarUrl;
  final Map<String, String> avatarHeaders;
  final Uri? matrixAvatarUri;
  final GroupMemberMembership membership;
  bool get isJoined => membership == GroupMemberMembership.joined;
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

abstract interface class GroupChatInfoReloadGateway {
  Future<GroupChatInfoSnapshot> load();
}

abstract interface class GroupAnnouncementGateway {
  GroupAnnouncementService get announcementService;
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
  StreamSubscription<void>? _membershipSubscription;

  /// Binds Matrix room updates so membership changes refresh this controller
  /// while the chat-info route stays open.
  void bindMembershipChanges(Stream<void> updates, {required String roomId}) {
    _membershipSubscription?.cancel();
    _membershipSubscription = updates.listen((_) {
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
        snapshot: gateway is GroupChatInfoReloadGateway
            ? await gateway.load()
            : update(snapshot),
      ));
    } catch (_) {
      var refreshed = snapshot;
      if (gateway is GroupChatInfoReloadGateway) {
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
