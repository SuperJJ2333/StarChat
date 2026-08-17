import 'package:flutter/cupertino.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'group_chat_info_controller.dart';

final class GroupChatInfoPage extends StatefulWidget {
  const GroupChatInfoPage({
    super.key,
    required this.controller,
    required this.onAddMember,
    required this.onSearchHistory,
    required this.onClearLocalHistory,
    required this.onLeft,
  });

  final GroupChatInfoController controller;
  final VoidCallback onAddMember;
  final VoidCallback onSearchHistory;
  final Future<void> Function() onClearLocalHistory;
  final VoidCallback onLeft;

  @override
  State<GroupChatInfoPage> createState() => _GroupChatInfoPageState();
}

final class _GroupChatInfoPageState extends State<GroupChatInfoPage> {
  static const collapsedMemberCount = 9;
  bool expanded = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _edit({
    required String title,
    required String initialValue,
    required int maxLength,
    required Future<void> Function(String value) save,
  }) async {
    final result = await Navigator.push<String>(
      context,
      CupertinoPageRoute(
        builder: (_) => _GroupTextEditPage(
          title: title,
          initialValue: initialValue,
          maxLength: maxLength,
        ),
      ),
    );
    if (result != null) await save(result);
  }

  Future<void> _confirmClear() async {
    final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('清空聊天记录'),
            content: const Text('只隐藏当前设备的本地聊天记录，不影响对方和其他设备。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed) await widget.onClearLocalHistory();
  }

  Future<void> _confirmLeave() async {
    final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('退出群聊'),
            content: const Text('退出后将不再接收该群聊消息。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('退出'),
              ),
            ],
          ),
        ) ??
        false;
    if (confirmed && await widget.controller.leave()) widget.onLeft();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final snapshot = state.snapshot;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(middle: Text(state.title)),
      child: SafeArea(
        child: snapshot == null
            ? Center(
                child: state.status == GroupChatInfoStatus.failed
                    ? CupertinoButton(
                        onPressed: widget.controller.load,
                        child: Text(state.message ?? '重新加载'),
                      )
                    : const CupertinoActivityIndicator(),
              )
            : ListView(
                children: [
                  _MemberGrid(
                    members: expanded
                        ? snapshot.members
                        : snapshot.members.take(collapsedMemberCount).toList(),
                    onAdd: widget.onAddMember,
                  ),
                  if (snapshot.members.length > collapsedMemberCount)
                    WeChatListTile(
                      title: const Center(child: Text('查看更多群成员')),
                      onTap: () => setState(() => expanded = !expanded),
                    ),
                  const SizedBox(height: 12),
                  _detailTile(
                    '群聊名称',
                    snapshot.name,
                    () => _edit(
                      title: '群聊名称',
                      initialValue: snapshot.name,
                      maxLength: 20,
                      save: widget.controller.rename,
                    ),
                  ),
                  _detailTile(
                    '群公告',
                    snapshot.announcement.isEmpty
                        ? '未设置'
                        : snapshot.announcement,
                    () => _edit(
                      title: '群公告',
                      initialValue: snapshot.announcement,
                      maxLength: 500,
                      save: widget.controller.setAnnouncement,
                    ),
                  ),
                  _detailTile(
                    '备注',
                    snapshot.remark.isEmpty ? '未设置' : snapshot.remark,
                    () => _edit(
                      title: '备注',
                      initialValue: snapshot.remark,
                      maxLength: 20,
                      save: widget.controller.setRemark,
                    ),
                  ),
                  const SizedBox(height: 12),
                  WeChatListTile(
                    title: const Text('查找聊天记录'),
                    trailing: const CupertinoListTileChevron(),
                    onTap: widget.onSearchHistory,
                  ),
                  _switchTile(
                    '消息免打扰',
                    snapshot.muted,
                    (value) => widget.controller.setPreference(
                      GroupChatPreference.muted,
                      value,
                    ),
                  ),
                  _switchTile(
                    '置顶聊天',
                    snapshot.pinned,
                    (value) => widget.controller.setPreference(
                      GroupChatPreference.pinned,
                      value,
                    ),
                  ),
                  _switchTile(
                    '保存到通讯录',
                    snapshot.saved,
                    (value) => widget.controller.setPreference(
                      GroupChatPreference.saved,
                      value,
                    ),
                  ),
                  const SizedBox(height: 12),
                  WeChatListTile(
                    title: const Text(
                      '清空聊天记录',
                      style: TextStyle(color: WeChatColors.danger),
                    ),
                    onTap: _confirmClear,
                  ),
                  WeChatListTile(
                    title: const Center(
                      child: Text(
                        '退出群聊',
                        style: TextStyle(color: WeChatColors.danger),
                      ),
                    ),
                    onTap: _confirmLeave,
                  ),
                  if (state.message != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        state.message!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: WeChatColors.danger),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }

  Widget _detailTile(String label, String detail, VoidCallback onTap) =>
      WeChatListTile(
        title: Text(label),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: WeChatColors.textSecondary),
              ),
            ),
            const SizedBox(width: 6),
            const CupertinoListTileChevron(),
          ],
        ),
        onTap: onTap,
      );

  Widget _switchTile(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      WeChatListTile(
        title: Text(label),
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );
}

final class _MemberGrid extends StatelessWidget {
  const _MemberGrid({required this.members, required this.onAdd});

  final List<GroupChatMember> members;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: WeChatColors.elevatedSurface(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          child: GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 14,
            crossAxisSpacing: 14,
            childAspectRatio: .72,
            children: [
              for (var index = 0; index < members.length; index++)
                _MemberCell(
                  key: Key('group-member-$index'),
                  member: members[index],
                ),
              _AddMemberCell(
                key: const Key('group-member-add'),
                onTap: onAdd,
              ),
            ],
          ),
        ),
      );
}

final class _MemberCell extends StatelessWidget {
  const _MemberCell({super.key, required this.member});
  final GroupChatMember member;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          UserAvatar(
            nickname: member.displayName,
            fallbackSeed: member.matrixUserId,
            avatarUrl: member.avatarUrl,
            size: 48,
          ),
          const SizedBox(height: 5),
          Text(
            member.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ],
      );
}

final class _AddMemberCell extends StatelessWidget {
  const _AddMemberCell({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                border: Border.all(color: WeChatColors.divider),
                borderRadius: BorderRadius.circular(WeChatRadius.control),
              ),
              child: const Icon(CupertinoIcons.person_add, size: 24),
            ),
            const SizedBox(height: 5),
            const Text('添加', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
}

final class _GroupTextEditPage extends StatefulWidget {
  const _GroupTextEditPage({
    required this.title,
    required this.initialValue,
    required this.maxLength,
  });

  final String title;
  final String initialValue;
  final int maxLength;

  @override
  State<_GroupTextEditPage> createState() => _GroupTextEditPageState();
}

final class _GroupTextEditPageState extends State<_GroupTextEditPage> {
  late final TextEditingController input =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(widget.title),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('完成'),
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: CupertinoTextField(
              controller: input,
              maxLength: widget.maxLength,
              maxLines: widget.maxLength > 20 ? 8 : 1,
              autofocus: true,
              padding: const EdgeInsets.all(14),
            ),
          ),
        ),
      );
}

final class GroupMemberPickerPage extends StatefulWidget {
  const GroupMemberPickerPage({
    super.key,
    required this.contacts,
    required this.existingMemberIds,
    required this.onInvite,
  });

  final List<ContactSummary> contacts;
  final Set<String> existingMemberIds;
  final Future<void> Function(String matrixUserId) onInvite;

  @override
  State<GroupMemberPickerPage> createState() => _GroupMemberPickerPageState();
}

final class _GroupMemberPickerPageState extends State<GroupMemberPickerPage> {
  final selected = <String>{};
  bool saving = false;

  Future<void> _complete() async {
    if (saving || selected.isEmpty) return;
    setState(() => saving = true);
    for (final matrixUserId in selected) {
      await widget.onInvite(matrixUserId);
    }
    if (mounted) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.contacts
        .where(
          (contact) => !widget.existingMemberIds.contains(contact.matrixUserId),
        )
        .toList(growable: false);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('添加群成员'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: selected.isEmpty || saving ? null : _complete,
          child: saving ? const CupertinoActivityIndicator() : const Text('完成'),
        ),
      ),
      child: SafeArea(
        child: ListView(
          children: [
            for (final contact in available)
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
          ],
        ),
      ),
    );
  }
}

final class GroupChatHistoryEntry {
  const GroupChatHistoryEntry({required this.sender, required this.text});
  final String sender;
  final String text;
}

final class GroupChatHistorySearchPage extends StatefulWidget {
  const GroupChatHistorySearchPage({super.key, required this.entries});
  final List<GroupChatHistoryEntry> entries;

  @override
  State<GroupChatHistorySearchPage> createState() =>
      _GroupChatHistorySearchPageState();
}

final class _GroupChatHistorySearchPageState
    extends State<GroupChatHistorySearchPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final results = widget.entries
        .where(
          (entry) =>
              normalized.isEmpty ||
              entry.text.toLowerCase().contains(normalized) ||
              entry.sender.toLowerCase().contains(normalized),
        )
        .toList(growable: false);
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('查找聊天记录')),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                placeholder: '搜索群成员或消息',
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final entry in results)
                    WeChatListTile(
                      title: Text(entry.sender),
                      subtitle: Text(entry.text),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
