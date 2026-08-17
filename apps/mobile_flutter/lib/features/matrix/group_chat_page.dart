import 'package:flutter/cupertino.dart';

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
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('发起群聊')),
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
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: ModernActionButton(
                          key: const Key('group-chat-create'),
                          icon: CupertinoIcons.person_3_fill,
                          label: '创建群聊（${state.selectedMatrixUserIds.length}）',
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
