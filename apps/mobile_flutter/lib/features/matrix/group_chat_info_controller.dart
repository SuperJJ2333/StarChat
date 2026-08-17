import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

const groupChatAccountDataType = 'com.liuhetong.group_chat.settings.v1';

enum GroupChatPreference { muted, pinned, saved }

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
  });

  final String name;
  final String announcement;
  final String remark;
  final List<GroupChatMember> members;
  final bool muted;
  final bool pinned;
  final bool saved;

  GroupChatInfoSnapshot copyWith({
    String? name,
    String? announcement,
    String? remark,
    List<GroupChatMember>? members,
    bool? muted,
    bool? pinned,
    bool? saved,
  }) =>
      GroupChatInfoSnapshot(
        name: name ?? this.name,
        announcement: announcement ?? this.announcement,
        remark: remark ?? this.remark,
        members: members ?? this.members,
        muted: muted ?? this.muted,
        pinned: pinned ?? this.pinned,
        saved: saved ?? this.saved,
      );
}

abstract interface class GroupChatInfoGateway {
  Future<GroupChatInfoSnapshot> load();
  Future<void> rename(String name);
  Future<void> setAnnouncement(String announcement);
  Future<void> setRemark(String remark);
  Future<void> setPreference(GroupChatPreference preference, bool value);
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
    final users = await room.requestParticipants([
      Membership.join,
      Membership.invite,
    ]);
    final settings = _settings;
    return GroupChatInfoSnapshot(
      name: room.getLocalizedDisplayname(),
      announcement: room.topic,
      remark: settings['remark']?.toString() ?? '',
      muted: settings['muted'] == true,
      pinned: settings['pinned'] == true,
      saved: settings['saved'] == true,
      members: [
        for (final user in users)
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
  ) =>
      _writeSetting(preference.name, value);

  @override
  Future<void> setRemark(String remark) => _writeSetting('remark', remark);

  Future<void> _writeSetting(String key, Object value) async {
    final userId = room.client.userID;
    if (userId == null) throw StateError('Matrix 账号尚未登录');
    final next = {..._settings, key: value};
    await room.client.setAccountDataPerRoom(
      userId,
      room.id,
      groupChatAccountDataType,
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
        },
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
