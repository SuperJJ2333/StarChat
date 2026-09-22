import 'package:flutter/foundation.dart';
import 'dart:async';
import '../../core/business_api_error.dart';

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

  /// BUG-24：撤回已发出的入群邀请（Matrix kick 对 invite 成员即撤回）。
  Future<void> withdrawInvite(String matrixUserId);
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

/// /groups/auto-join 失败桶条目（BUG-24：失败原因必须保留，用于如实提示）。
final class GroupAutoJoinFailure {
  const GroupAutoJoinFailure({required this.userId, this.code});
  final String userId;

  /// `GROUP_INVITEE_UNAVAILABLE` = 账号被限制（封禁/禁用），永远无法加入。
  final String? code;
  bool get isUnavailable => code == 'GROUP_INVITEE_UNAVAILABLE';
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
            .map((entry) => GroupAutoJoinFailure(
                  userId: entry['user_id']?.toString() ?? '',
                  code: entry['code']?.toString(),
                ))
            .where((failure) => failure.userId.isNotEmpty)
            .toList(growable: false),
      );

  final List<String> joinedUserIds;
  final List<String> pendingUserIds;
  final List<GroupAutoJoinFailure> failed;
  bool get hasFailures => failed.isNotEmpty;

  /// 有被限制（封禁/禁用）的受邀人：邀请永远无法兑现，必须如实提示并撤回。
  bool get hasUnavailableInvitee =>
      failed.any((failure) => failure.isUnavailable);
  List<String> get unavailableUserIds => [
        for (final failure in failed)
          if (failure.isUnavailable) failure.userId,
      ];
}

final class GroupChatInfoController extends ChangeNotifier {
  GroupChatInfoController(this.gateway,
      {this.serverAutoJoin,
      this.submitOwnershipTransfer,
      this.loadOwnershipTransfers});

  final Future<Map<String, dynamic>> Function(String targetMatrixUserId)?
      submitOwnershipTransfer;
  final Future<List<Map<String, dynamic>>> Function()? loadOwnershipTransfers;
  Map<String, dynamic>? ownershipTransfer;
  bool ownershipTransferReadUnsupported = false;
  String? get ownershipTransferCompatibilityMessage =>
      ownershipTransferReadUnsupported && ownershipTransfer == null
          ? '当前服务器暂不支持转让状态查询，群权限按当前群聊显示；新的群主转让需等待服务器支持'
          : null;

  bool _isUnsupportedTransferRead(Object error) =>
      error is BusinessApiException &&
      {404, 405, 501}.contains(error.statusCode);
  String? _transferTarget;
  bool get ownershipTransferPending =>
      ownershipTransfer != null &&
      !{'COMPLETED', 'FAILED'}.contains(ownershipTransfer!['stage']);
  String get ownershipTransferMessage => switch (ownershipTransfer?['stage']) {
        'COMPLETED' => '群主转让已完成',
        'NEEDS_REVIEW' => '转让待人工核对，确认完成前群主身份保持不变',
        'FAILED' => '转让未完成，请重试或联系客服',
        _ => '转让处理中，确认完成前群主身份保持不变',
      };

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
      if (state.status != GroupChatInfoStatus.loading &&
          state.status != GroupChatInfoStatus.saving) {
        unawaited(load());
      }
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
      final previousOwner = state.snapshot?.ownerId;
      var snapshot = await gateway.load();
      if (ownershipTransfer == null && loadOwnershipTransfers != null) {
        try {
          final intents = await loadOwnershipTransfers!();
          ownershipTransferReadUnsupported = false;
          if (intents.isNotEmpty) ownershipTransfer = intents.first;
        } catch (error) {
          ownershipTransferReadUnsupported = _isUnsupportedTransferRead(error);
          /* Group metadata remains available when status cannot load. */
        }
      }
      if (ownershipTransferPending) {
        snapshot = snapshot.copyWith(
            ownerId:
                ownershipTransfer?['expected_old_owner_matrix_id'] as String? ??
                    previousOwner ??
                    '');
      }
      _set(GroupChatInfoState(
        status: GroupChatInfoStatus.ready,
        snapshot: snapshot,
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

  Future<void> transferOwnership(String id) async {
    if (state.status == GroupChatInfoStatus.saving ||
        ownershipTransferPending) {
      return;
    }
    final snapshot = state.snapshot;
    try {
      _requireManager(ownerOnly: true);
      final submit = submitOwnershipTransfer;
      if (submit == null) throw StateError('unavailable');
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.saving, snapshot: snapshot));
      _transferTarget = id;
      ownershipTransfer = await submit(id);
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.ready,
          snapshot: ownershipTransfer?['stage'] == 'COMPLETED'
              ? snapshot!.copyWith(ownerId: id)
              : snapshot,
          message: ownershipTransferMessage));
    } catch (error) {
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.failed,
          snapshot: snapshot,
          message: error is BusinessApiException
              ? error.message
              : '群主转让暂不可用，请稍后重试'));
    }
  }

  Future<void> refreshOwnershipTransfer() async {
    final read = loadOwnershipTransfers;
    if (read == null || state.status == GroupChatInfoStatus.saving) return;
    final snapshot = state.snapshot;
    _set(GroupChatInfoState(
        status: GroupChatInfoStatus.saving, snapshot: snapshot));
    try {
      final intents = await read();
      ownershipTransferReadUnsupported = false;
      final currentId =
          ownershipTransfer?['transfer_id'] ?? ownershipTransfer?['id'];
      final matching = currentId == null
          ? intents
          : intents.where((entry) => entry['id'] == currentId).toList();
      if (matching.isNotEmpty) ownershipTransfer = matching.first;
      var next = snapshot;
      if (ownershipTransferPending &&
          ownershipTransfer!.containsKey('expected_old_owner_matrix_id')) {
        next = snapshot?.copyWith(
            ownerId:
                ownershipTransfer!['expected_old_owner_matrix_id'] as String);
      }
      if (ownershipTransfer?['stage'] == 'COMPLETED') {
        next = _transferTarget == null
            ? await gateway.load()
            : snapshot?.copyWith(ownerId: _transferTarget);
      }
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.ready,
          snapshot: next,
          message:
              ownershipTransfer == null ? null : ownershipTransferMessage));
    } catch (error) {
      if (ownershipTransfer == null && _isUnsupportedTransferRead(error)) {
        ownershipTransferReadUnsupported = true;
        _set(GroupChatInfoState(
            status: GroupChatInfoStatus.ready, snapshot: snapshot));
        return;
      }
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.failed,
          snapshot: snapshot,
          message: '转让状态暂未获取，请重试'));
    }
  }

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
        } else if (outcome.hasUnavailableInvitee) {
          // BUG-24 补齐：被限制账号永远无法加入，不得谎报「等待对方确认」；
          // 同时撤回已发出的 Matrix 邀请（kick 即撤回）。
          joinMessage = '该账号已被限制，无法加入群聊';
          // 撤回对象是本次被邀的 Matrix 账号（outcome 里的 id 是业务 id）。
          try {
            await gateway.withdrawInvite(matrixUserId);
          } catch (_) {/* 撤回失败不改变提示；成员事件会修正列表 */}
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
    if (ownershipTransferPending) {
      _set(GroupChatInfoState(
          status: GroupChatInfoStatus.ready,
          snapshot: state.snapshot,
          message: ownershipTransferMessage));
      return false;
    }
    try {
      // BUG-29：群主退出且群内仍有其他成员时，先把群主转移给（列表序
      // 最早的）其他成员，避免群因退出而失去群主；转移失败则不退出。
      final snapshot = state.snapshot;
      if (snapshot != null && snapshot.ownerId == snapshot.currentUserId) {
        final successor = snapshot.members
            .where((member) =>
                member.isJoined &&
                member.matrixUserId != snapshot.currentUserId)
            .map((member) => member.matrixUserId)
            .firstOrNull;
        if (successor != null) {
          await transferOwnership(successor);
          if (ownershipTransfer?['stage'] != 'COMPLETED') return false;
        }
      }
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
