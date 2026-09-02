import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/foundation/wechat_tokens.dart';

import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/changliao_icons.dart';
import 'group_chat_controller.dart';

final class GroupChatPage extends StatefulWidget {
  const GroupChatPage({
    super.key,
    required this.controller,
    required this.onCreated,
  });

  final GroupChatController controller;
  final ValueChanged<String> onCreated;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

final class _GroupChatPageState extends State<GroupChatPage> {
  final name = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    name.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _create() async {
    final roomId = await widget.controller.create(name.text);
    if (roomId != null && mounted) widget.onCreated(roomId);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('发起群聊')),
      child: SafeArea(
        child: state.status == GroupChatStatus.loading ||
                state.status == GroupChatStatus.idle
            ? const Center(child: CupertinoActivityIndicator())
            : state.contacts.isEmpty
                ? Center(
                    child: ModernActionButton(
                      icon: ChangliaoIcons.retry,
                      label: state.message ?? '暂无可邀请的好友',
                      onPressed: widget.controller.load,
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: CupertinoTextField(
                          key: const Key('group-chat-name'),
                          controller: name,
                          placeholder: '群聊名称（可选）',
                          maxLength: 20,
                          padding: const EdgeInsets.all(14),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: state.contacts.length,
                          itemBuilder: (_, index) {
                            final contact = state.contacts[index];
                            final selected = state.selectedMatrixUserIds
                                .contains(contact.matrixUserId);
                            return CupertinoListTile(
                              leading: UserAvatar(
                                nickname: contact.displayName,
                                fallbackSeed: contact.username,
                                avatarUrl: contact.avatarUrl,
                                size: 40,
                              ),
                              title: Text(contact.displayName),
                              trailing: Icon(
                                selected
                                    ? CupertinoIcons.check_mark_circled_solid
                                    : CupertinoIcons.circle,
                                color: selected
                                    ? CupertinoColors.activeGreen
                                    : CupertinoColors.systemGrey,
                              ),
                              onTap: () => widget.controller
                                  .toggle(contact.matrixUserId),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(
                          // 群聊人数下限 3 人（含自己）；仅选 1 人无法创建，
                          // 如需单聊请使用好友"发消息"。
                          state.selectedMatrixUserIds.length < 2
                              ? '群聊至少需要 3 名成员（含你自己）。'
                                  '仅选择 1 位联系人时无法创建；'
                                  '如需单聊请回到会话列表直接发起。'
                              : '创建后将以加密群聊运行',
                          key: const Key('group-chat-min-hint'),
                          style: const TextStyle(
                              fontSize: 12,
                              color: WeChatColors.textSecondary),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: ModernActionButton(
                          key: const Key('group-chat-create'),
                          icon: CupertinoIcons.person_3_fill,
                          label:
                              '创建群聊（${state.selectedMatrixUserIds.length + 1}）',
                          loading: state.status == GroupChatStatus.creating,
                          onPressed:
                              widget.controller.canCreate ? _create : null,
                        ),
                      ),
                      if (state.message != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            state.message!,
                            style: const TextStyle(
                              color: CupertinoColors.systemRed,
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}
