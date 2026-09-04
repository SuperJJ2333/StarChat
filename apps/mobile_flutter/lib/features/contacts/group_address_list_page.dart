import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:matrix/matrix.dart';

import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../../ui/chat/group_avatar_mosaic.dart';
import '../matrix/conversation_preferences.dart';
import '../matrix/matrix_home_page.dart' show orderedJoinedMembers;
import '../matrix/matrix_user_avatar.dart';

/// BUG4：群聊通讯录——只显示当前用户已 join、非私聊、且开了
/// 「保存到通讯录」（room account data `saved=true`，个人设置不泄露给
/// 其他成员）的群聊；按最近活跃倒序；随 Matrix 同步与保存状态即时刷新。
final class GroupAddressListPage extends StatefulWidget {
  const GroupAddressListPage({super.key, required this.client, this.onOpen});

  final Client client;

  /// 点击进入会话（组合根注入 RoomPage 打开路径）。
  final void Function(Room room)? onOpen;

  @override
  State<GroupAddressListPage> createState() => _GroupAddressListPageState();
}

final class _GroupAddressListPageState extends State<GroupAddressListPage> {
  StreamSubscription<SyncUpdate>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.client.onSync.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  List<Room> _savedGroups() {
    final rooms = widget.client.rooms
        .where((room) =>
            room.membership == Membership.join && !room.isDirectChat)
        .where((room) => preferenceForRoom(room).saved)
        .toList(growable: false)
      ..sort((a, b) {
        final left = a.lastEvent?.originServerTs ?? DateTime.fromMillisecondsSinceEpoch(0);
        final right = b.lastEvent?.originServerTs ?? DateTime.fromMillisecondsSinceEpoch(0);
        return right.compareTo(left);
      });
    return rooms;
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
    final rooms = _savedGroups();
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
      separatorBuilder: (_, __) => const Padding(
        padding: EdgeInsets.only(
            left: WeChatSpacing.lg + 40 + WeChatSpacing.md),
        child: SizedBox(height: 0.5, child: ColoredBox(color: WeChatColors.divider)),
      ),
      itemBuilder: (context, index) {
        final room = rooms[index];
        final members = orderedJoinedMembers(room);
        final name = room.name.trim().isEmpty ? '未命名群聊' : room.name.trim();
        return _GroupAddressTile(
          room: room,
          name: name,
          memberCount: members.length,
          onTap: () => widget.onOpen?.call(room),
        );
      },
    );
  }
}

final class _GroupAddressTile extends StatelessWidget {
  const _GroupAddressTile({
    required this.room,
    required this.name,
    required this.memberCount,
    this.onTap,
  });

  final Room room;
  final String name;
  final int memberCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CupertinoListTile(
        key: ValueKey<String>('group-address-${room.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: room.avatar != null
            ? MatrixUserAvatar(
                client: room.client,
                nickname: name,
                fallbackSeed: room.id,
                matrixAvatarUri: room.avatar,
                size: 40,
              )
            : GroupAvatarMosaic(
                avatars: [
                  for (final member in orderedJoinedMembers(room).take(9))
                    MatrixUserAvatar(
                      client: room.client,
                      nickname: member.calcDisplayname(),
                      fallbackSeed: member.id,
                      matrixAvatarUri: member.avatarUrl,
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
          style: const TextStyle(
              fontSize: 12, color: WeChatColors.textSecondary),
        ),
        trailing: const Icon(CupertinoIcons.chevron_right, size: 14),
        onTap: onTap,
      );
}

/// 轻量刷新信号：info 页保存开关变更时通知（跨路由）。
final class _PreferenceRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
