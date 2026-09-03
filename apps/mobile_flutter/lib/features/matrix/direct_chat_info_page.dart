import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';
import 'package:matrix/matrix.dart';

import 'matrix_user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'conversation_preferences.dart';
import '../../ui/notification/conversation_notification_mode_tile.dart';

final class DirectChatInfoPage extends StatefulWidget {
  const DirectChatInfoPage({
    super.key,
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
            ConversationNotificationModeTile(
              muted: preference.muted,
              attention: preference.attention,
              onChanged: (mode) => _update(preference.copyWith(
                muted: mode == ConversationNotificationMode.muted,
                attention: mode == ConversationNotificationMode.attention,
              )),
            ),
            _switch('置顶聊天', preference.pinned, (value) {
              _update(preference.copyWith(
                pinned: value,
                pinnedAt: value ? DateTime.now().toUtc() : null,
                clearPinnedAt: !value,
              ));
            }),
            _switch('保存到通讯录', preference.saved,
                (value) => _update(preference.copyWith(saved: value))),
            const SizedBox(height: 12),
            WeChatListTile(
              title: const Text(
                '清空聊天记录',
                style: TextStyle(color: WeChatColors.danger),
              ),
              onTap: _clear,
            ),
          ]),
        ),
      );

  Widget _person(String name, String id, String? avatarUrl) =>
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
