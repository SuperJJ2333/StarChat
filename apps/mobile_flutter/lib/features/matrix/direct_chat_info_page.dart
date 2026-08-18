import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'conversation_preferences.dart';
import '../contacts/contact_models.dart';

final class DirectChatInfoPage extends StatefulWidget {
  const DirectChatInfoPage({
    super.key,
    required this.peerName,
    required this.peerId,
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

final class DirectGroupMemberPickerPage extends StatefulWidget {
  const DirectGroupMemberPickerPage({
    super.key,
    required this.contacts,
    required this.peerId,
    required this.onCreate,
  });
  final List<ContactSummary> contacts;
  final String peerId;
  final Future<void> Function(List<String> inviteeIds) onCreate;

  @override
  State<DirectGroupMemberPickerPage> createState() =>
      _DirectGroupMemberPickerPageState();
}

final class _DirectGroupMemberPickerPageState
    extends State<DirectGroupMemberPickerPage> {
  final selected = <String>{};
  bool saving = false;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: const Text('发起群聊'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: selected.isEmpty || saving
                ? null
                : () async {
                    setState(() => saving = true);
                    await widget.onCreate([widget.peerId, ...selected]);
                    if (context.mounted) Navigator.pop(context);
                  },
            child:
                saving ? const CupertinoActivityIndicator() : const Text('完成'),
          ),
        ),
        child: SafeArea(
          child: ListView(children: [
            for (final contact in widget.contacts)
              if (contact.matrixUserId != widget.peerId)
                WeChatListTile(
                  leading: UserAvatar(
                    nickname: contact.displayName,
                    fallbackSeed: contact.username,
                    avatarUrl: contact.avatarUrl,
                    size: 40,
                  ),
                  title: Text(contact.displayName),
                  trailing: Icon(
                    selected.contains(contact.matrixUserId)
                        ? CupertinoIcons.check_mark_circled_solid
                        : CupertinoIcons.circle,
                    color: selected.contains(contact.matrixUserId)
                        ? WeChatColors.brandPrimary
                        : WeChatColors.textTertiary,
                  ),
                  onTap: () => setState(() {
                    selected.contains(contact.matrixUserId)
                        ? selected.remove(contact.matrixUserId)
                        : selected.add(contact.matrixUserId);
                  }),
                ),
          ]),
        ),
      );
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
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('聊天信息')),
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
            if (widget.onEditNudge != null)
              WeChatListTile(
                title: const Text('设置拍一拍'),
                trailing: const CupertinoListTileChevron(),
                onTap: widget.onEditNudge,
              ),
            _switch('消息免打扰', preference.muted,
                (value) => _update(preference.copyWith(muted: value))),
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
        UserAvatar(
          nickname: name,
          fallbackSeed: id,
          avatarUrl: avatarUrl,
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
