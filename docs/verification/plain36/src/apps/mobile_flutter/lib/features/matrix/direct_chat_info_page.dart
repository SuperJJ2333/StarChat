import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';
import 'package:matrix/matrix.dart';

import 'matrix_user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'conversation_preferences.dart';
import '../../ui/notification/conversation_notification_mode_tile.dart';

final class DirectChatInfoPage extends StatefulWidget {
  /// 规格§八：好友头像点击（参数 userId）→ 好友资料页。
  final void Function(String userId)? onTapPerson;

  const DirectChatInfoPage({
    super.key,
    this.onTapPerson,
    required this.peerName,
    required this.peerId,
    required this.matrixClient,
    required this.preference,
    required this.onAddMember,
    required this.onSearchHistory,
    required this.onClearLocalHistory,
    required this.onPreferenceChanged,
    this.peerAvatarUrl,
    this.onEditNudge,
  });

  final String peerName;
  final String peerId;
  final Client matrixClient;
  final String? peerAvatarUrl;
  final ConversationPreference preference;
  final VoidCallback onAddMember;
  final VoidCallback onSearchHistory;
  final Future<void> Function() onClearLocalHistory;
  final Future<void> Function(ConversationPreference preference)
      onPreferenceChanged;
  final VoidCallback? onEditNudge;

  @override
  State<DirectChatInfoPage> createState() => _DirectChatInfoPageState();
}

final class _DirectChatInfoPageState extends State<DirectChatInfoPage> {
  late ConversationPreference preference = widget.preference;

  Future<void> _update(ConversationPreference next) async {
    setState(() => preference = next);
    await widget.onPreferenceChanged(next);
  }

  Future<void> _clear() async {
    final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('清空聊天记录'),
            content: const Text('只隐藏当前设备的本地聊天记录，不影响对方和其他设备。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) await widget.onClearLocalHistory();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('聊天信息')),
        child: SafeArea(
          child: ListView(children: [
            ColoredBox(
              color: WeChatColors.elevatedSurface(context),
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(children: [
                  _person(widget.peerName, widget.peerId, widget.peerAvatarUrl),
                  const SizedBox(width: 18),
                  CupertinoButton(
                    key: const Key('direct-chat-add-member'),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onAddMember,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          border: Border.all(color: WeChatColors.divider),
                          borderRadius:
                              BorderRadius.circular(WeChatRadius.control),
                        ),
                        child: const Icon(CupertinoIcons.person_add, size: 24),
                      ),
                      const SizedBox(height: 5),
                      const Text('添加', style: TextStyle(fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            WeChatListTile(
              title: const Text('查找聊天记录'),
              trailing: const CupertinoListTileChevron(),
              onTap: widget.onSearchHistory,
            ),
            // PRD §44：会话通知三态（默认 / 静音 / 特别关注）。
            // 规格§四：一级菜单"消息通知 >"默认收起，点开再选三态。
            _notificationSection(),
            _switch('置顶聊天', preference.pinned, (value) {
              _update(preference.copyWith(
                pinned: value,
                pinnedAt: value ? DateTime.now().toUtc() : null,
                clearPinnedAt: !value,
              ));
            }),
            const SizedBox(height: 12),
            Center(
              child: WeChatListTile(
                title: const Text(
                  '清空聊天记录',
                  style: TextStyle(color: WeChatColors.danger),
                ),
                onTap: _clear,
              ),
            ),
          ]),
        ),
      );

  bool _notificationExpanded = false;

  Widget _notificationSection() {
    final mode = preference.muted
        ? ConversationNotificationMode.muted
        : preference.attention
            ? ConversationNotificationMode.attention
            : ConversationNotificationMode.normal;
    final modeLabel = switch (mode) {
      ConversationNotificationMode.muted => '静音',
      ConversationNotificationMode.attention => '特别关注',
      _ => '默认',
    };
    return Column(children: [
      WeChatListTile(
        title: const Text('消息通知'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(modeLabel,
              style: const TextStyle(
                  fontSize: 14, color: WeChatColors.textSecondary)),
          const CupertinoListTileChevron(),
        ]),
        onTap: () => setState(() => _notificationExpanded = !_notificationExpanded),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: _notificationExpanded
            ? ConversationNotificationModeTile(
                muted: preference.muted,
                attention: preference.attention,
                onChanged: (m) {
                  setState(() => _notificationExpanded = false);
                  _update(preference.copyWith(
                    muted: m == ConversationNotificationMode.muted,
                    attention: m == ConversationNotificationMode.attention,
                  ));
                },
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }

  Widget _person(String name, String id, String? avatarUrl) =>
      GestureDetector(
        // 规格§八：点击头像进入 APP 自己的好友资料页（onTapPerson 由
        // RoomPage 注入，携带 userId；禁止打开 Matrix Profile）。
        onTap: () => widget.onTapPerson?.call(id),
        child: _personColumn(name, id, avatarUrl),
      );

  Widget _personColumn(String name, String id, String? avatarUrl) =>
      Column(mainAxisSize: MainAxisSize.min, children: [
        MatrixUserAvatar(
          client: widget.matrixClient,
          nickname: name,
          fallbackSeed: id,
          matrixAvatarUri: Uri.tryParse(avatarUrl ?? ''),
          fallbackAvatarUrl: avatarUrl,
          size: 48,
        ),
        const SizedBox(height: 5),
        SizedBox(
          width: 54,
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]);

  Widget _switch(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      WeChatListTile(
        title: Text(label),
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );
}
