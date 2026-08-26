import 'package:flutter/foundation.dart';
import 'dart:async';

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
    try {
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
