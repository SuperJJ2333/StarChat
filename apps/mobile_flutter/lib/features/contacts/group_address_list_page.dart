import 'dart:async';

import 'package:flutter/cupertino.dart';
import '../matrix/matrix_e2ee_client.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/chat/group_avatar_mosaic.dart';
import '../matrix/matrix_user_avatar.dart';
import '../matrix/profile_repository.dart';

/// BUG4：群聊通讯录——只显示当前用户已 join、非私聊、且开了
/// 「保存到通讯录」（room account data `saved=true`，个人设置不泄露给
/// 其他成员）的群聊；按最近活跃倒序；随 Matrix 同步与保存状态即时刷新。
final class GroupAddressListPage extends StatefulWidget {
  const GroupAddressListPage(
      {super.key, required this.matrix, this.onOpen, this.identityCache});
  final ProfileRepository? identityCache;

  final MatrixSdkE2eeClient matrix;

  /// 点击进入会话（组合根注入 RoomPage 打开路径）。
  final void Function(String roomId)? onOpen;

  @override
  State<GroupAddressListPage> createState() => _GroupAddressListPageState();
}

final class _GroupAddressListPageState extends State<GroupAddressListPage> {
  StreamSubscription<void>? _subscription;

  @override
  void initState() {
    super.initState();
    widget.identityCache?.addListener(_identityChanged);
    _subscription =
        widget.matrix.syncEvents.listen((_) => unawaited(_refresh()));
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    widget.identityCache?.removeListener(_identityChanged);
    super.dispose();
  }

  void _identityChanged() {
    if (mounted) setState(() {});
  }

  List<MatrixConversationRoomSnapshot> _rooms = [];
  int _generation = 0;
  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final snapshot = await widget.matrix.conversations.snapshot();
      if (!mounted || generation != _generation) return;
      final rooms = snapshot.rooms
          .where((room) =>
              room.isJoined && !room.isDirect && room.preference.saved)
          .toList()
        ..sort((a, b) => (b.lastEvent?.originServerTs ?? DateTime(1970))
            .compareTo(a.lastEvent?.originServerTs ?? DateTime(1970)));
      setState(() => _rooms = rooms);
    } catch (_) {
      // Keep cached group entries available while the connection recovers.
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: const CupertinoNavigationBar(middle: Text('群聊')),
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _preferenceNotifier,
            builder: (context, _) => _buildList(context),
          ),
        ),
      );

  /// 保存状态写入是 setAccountDataPerRoom——通过客户端 onSync 之外的
  /// 路由返回刷新（本页 pop 回调后由父页重建），这里用轻量内部通知器
  /// 在路由返回时兜底刷新。
  static final _preferenceNotifier = _PreferenceRefreshNotifier();

  Widget _buildList(BuildContext context) {
    final rooms = _rooms;
    if (rooms.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(CupertinoIcons.person_3_fill,
                size: 44, color: WeChatColors.textTertiary),
            const SizedBox(height: 10),
            const Text(
              '暂无保存的群聊',
              key: Key('group-address-empty'),
              style: TextStyle(color: WeChatColors.textSecondary),
            ),
            const SizedBox(height: 6),
            const Text(
              '在群聊的「聊天信息」中打开「保存到通讯录」即可显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: WeChatColors.textTertiary),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      key: const Key('group-address-list'),
      padding: EdgeInsets.zero,
      itemCount: rooms.length,
      separatorBuilder: (_, __) => Padding(
        padding:
            EdgeInsets.only(left: WeChatSpacing.lg + 40 + WeChatSpacing.md),
        child: SizedBox(
            height: 0.5,
            child: ColoredBox(
                color: WeChatColors.resolve(context, WeChatColors.divider))),
      ),
      itemBuilder: (context, index) {
        final room = rooms[index];
        final members = room.members;
        final name =
            room.displayName.trim().isEmpty ? '未命名群聊' : room.displayName.trim();
        return _GroupAddressTile(
          identityCache: widget.identityCache,
          room: room,
          avatarMedia: widget.matrix,
          name: name,
          memberCount: members.length,
          onTap: () => widget.onOpen?.call(room.id),
        );
      },
    );
  }
}

final class _GroupAddressTile extends StatelessWidget {
  const _GroupAddressTile({
    required this.room,
    this.identityCache,
    required this.avatarMedia,
    required this.name,
    required this.memberCount,
    this.onTap,
  });

  final MatrixConversationRoomSnapshot room;
  final ProfileRepository? identityCache;
  final AvatarMediaCapability avatarMedia;
  final String name;
  final int memberCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CupertinoListTile(
        key: ValueKey<String>('group-address-${room.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: room.avatar != null
            ? MatrixUserAvatar(
                avatarMedia: avatarMedia,
                nickname: name,
                fallbackSeed: room.id,
                matrixAvatarUri: room.avatar,
                size: 40,
              )
            : GroupAvatarMosaic(
                avatars: [
                  for (final member in room.members.take(9))
                    MatrixUserAvatar(
                      avatarMedia: avatarMedia,
                      nickname: identityCache
                              ?.resolveIdentity(
                                  matrixUserId: member.id,
                                  displayName: member.displayName)
                              .displayName ??
                          member.displayName,
                      fallbackSeed: identityCache
                              ?.resolveIdentity(matrixUserId: member.id)
                              .cacheKey ??
                          member.id,
                      matrixAvatarUri: (identityCache
                                  ?.resolveIdentity(matrixUserId: member.id)
                                  .avatarIsKnown ??
                              false)
                          ? null
                          : member.avatar,
                      fallbackAvatarUrl: identityCache
                          ?.resolveIdentity(matrixUserId: member.id)
                          .avatarUrl,
                    ),
                ],
              ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        additionalInfo: Text(
          '$memberCount 人',
          key: ValueKey<String>('group-address-count-${room.id}'),
          style:
              const TextStyle(fontSize: 12, color: WeChatColors.textSecondary),
        ),
        trailing: const Icon(CupertinoIcons.chevron_right, size: 14),
        onTap: onTap,
      );
}

/// 轻量刷新信号：info 页保存开关变更时通知（跨路由）。
final class _PreferenceRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
