import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_scaffold.dart';

import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'group_chat_info_controller.dart';
import 'chat_history_search.dart';
import 'matrix_user_avatar.dart';

final class GroupChatInfoPage extends StatefulWidget {
  const GroupChatInfoPage({
    super.key,
    required this.controller,
    required this.onAddMember,
    required this.onSearchHistory,
    required this.onClearLocalHistory,
    required this.onLeft,
    this.onMemberTap,
  });

  final GroupChatInfoController controller;
  final VoidCallback onAddMember;
  final VoidCallback onSearchHistory;
  final Future<void> Function() onClearLocalHistory;
  final VoidCallback onLeft;
  final ValueChanged<GroupChatMember>? onMemberTap;

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
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: Text(state.title),
        trailing: snapshot == null
            ? null
            : CupertinoButton(
                key: const Key('group-member-search'),
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => GroupMemberSearchPage(snapshot: snapshot),
                  ),
                ),
                child: const Icon(CupertinoIcons.search),
              ),
      ),
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
                    onMemberTap: widget.onMemberTap,
                    onRemove: snapshot.canManage
                        ? () => Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => GroupMemberRemovalPage(
                                  controller: widget.controller,
                                ),
                              ),
                            )
                        : null,
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
                  _detailTile(
                    '群二维码',
                    snapshot.qrJoinEnabled ? '扫一扫加入群聊' : '已关闭',
                    () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => GroupQrCodePage(snapshot: snapshot),
                      ),
                    ),
                  ),
                  if (snapshot.canManage)
                    WeChatListTile(
                      title: const Text('群管理'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => Navigator.push(
                        context,
                        CupertinoPageRoute(
                          builder: (_) => GroupManagementPage(
                            controller: widget.controller,
                          ),
                        ),
                      ),
                    ),
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
                  if (snapshot.muted) ...[
                    _switchTile(
                      '折叠该聊天',
                      snapshot.folded,
                      (value) => widget.controller.setPreference(
                        GroupChatPreference.folded,
                        value,
                      ),
                    ),
                    WeChatListTile(
                      title: const Text('以下消息仍通知'),
                      subtitle: const Text('@我、@所有人和群公告'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: () => Navigator.push(
                        context,
                        CupertinoPageRoute(
                          builder: (_) => MuteExceptionSettingsPage(
                            controller: widget.controller,
                          ),
                        ),
                      ),
                    ),
                  ],
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

final class MuteExceptionSettingsPage extends StatelessWidget {
  const MuteExceptionSettingsPage({super.key, required this.controller});
  final GroupChatInfoController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.state.snapshot!;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('以下消息仍通知')),
      child: SafeArea(
        child: ListView(children: [
          _preferenceTile(
            '＠我',
            snapshot.notifyMentionMe,
            (value) => controller.setPreference(
              GroupChatPreference.notifyMentionMe,
              value,
            ),
          ),
          _preferenceTile(
            '＠所有人',
            snapshot.notifyMentionAll,
            (value) => controller.setPreference(
              GroupChatPreference.notifyMentionAll,
              value,
            ),
          ),
          _preferenceTile(
            '群公告',
            snapshot.notifyAnnouncement,
            (value) => controller.setPreference(
              GroupChatPreference.notifyAnnouncement,
              value,
            ),
          ),
          const SizedBox(height: 12),
          WeChatListTile(
            title: const Text('关注群成员的消息'),
            subtitle: const Text('最多可关注 4 位'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(
                '${snapshot.followedMemberIds.length}/4',
                style: const TextStyle(color: WeChatColors.textSecondary),
              ),
              const SizedBox(width: 6),
              const CupertinoListTileChevron(),
            ]),
            onTap: () => Navigator.push(
              context,
              CupertinoPageRoute(
                builder: (_) => FollowedGroupMemberPickerPage(
                  controller: controller,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _preferenceTile(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      WeChatListTile(
        title: Text(label),
        trailing: CupertinoSwitch(value: value, onChanged: onChanged),
      );
}

final class FollowedGroupMemberPickerPage extends StatefulWidget {
  const FollowedGroupMemberPickerPage({super.key, required this.controller});
  final GroupChatInfoController controller;

  @override
  State<FollowedGroupMemberPickerPage> createState() =>
      _FollowedGroupMemberPickerPageState();
}

final class _FollowedGroupMemberPickerPageState
    extends State<FollowedGroupMemberPickerPage> {
  late final Set<String> selected =
      widget.controller.state.snapshot!.followedMemberIds.toSet();

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.state.snapshot!;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('关注群成员'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () async {
            await widget.controller.setFollowedMemberIds(selected.toList());
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('完成'),
        ),
      ),
      child: SafeArea(
        child: ListView(children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '最多可关注 4 位群成员',
              style: TextStyle(color: WeChatColors.textSecondary),
            ),
          ),
          for (final member in snapshot.members)
            WeChatListTile(
              leading: UserAvatar(
                nickname: member.displayName,
                fallbackSeed: member.matrixUserId,
                avatarUrl: member.avatarUrl,
                avatarHeaders: member.avatarHeaders,
                size: 40,
              ),
              title: Text(member.displayName),
              trailing: Icon(
                selected.contains(member.matrixUserId)
                    ? CupertinoIcons.check_mark_circled_solid
                    : CupertinoIcons.circle,
                color: selected.contains(member.matrixUserId)
                    ? WeChatColors.brandPrimary
                    : WeChatColors.textTertiary,
              ),
              onTap: () => setState(() {
                if (!selected.remove(member.matrixUserId) &&
                    selected.length < 4) {
                  selected.add(member.matrixUserId);
                }
              }),
            ),
        ]),
      ),
    );
  }
}

final class _MemberGrid extends StatelessWidget {
  const _MemberGrid(
      {required this.members,
      required this.onAdd,
      this.onMemberTap,
      this.onRemove});

  final List<GroupChatMember> members;
  final VoidCallback onAdd;
  final ValueChanged<GroupChatMember>? onMemberTap;
  final VoidCallback? onRemove;

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
                  key: Key('group-member-${members[index].matrixUserId}'),
                  member: members[index],
                  onTap: onMemberTap == null
                      ? null
                      : () => onMemberTap!(members[index]),
                ),
              _AddMemberCell(
                key: const Key('group-member-add'),
                onTap: onAdd,
              ),
              if (onRemove != null)
                _RemoveMemberCell(
                  key: const Key('group-member-remove'),
                  onTap: onRemove!,
                ),
            ],
          ),
        ),
      );
}

final class _RemoveMemberCell extends StatelessWidget {
  const _RemoveMemberCell({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => CupertinoButton(
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Column(children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              border: Border.all(color: WeChatColors.divider),
              borderRadius: BorderRadius.circular(WeChatRadius.control),
            ),
            child: const Icon(CupertinoIcons.minus, size: 24),
          ),
          const SizedBox(height: 5),
          const Text('移除', style: TextStyle(fontSize: 12)),
        ]),
      );
}

final class GroupQrCodePage extends StatelessWidget {
  const GroupQrCodePage({super.key, required this.snapshot});
  final GroupChatInfoSnapshot snapshot;

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('群二维码')),
        child: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(CupertinoIcons.qrcode, size: 176),
              const SizedBox(height: 16),
              Text(snapshot.name.isEmpty ? '群聊' : snapshot.name),
              const SizedBox(height: 8),
              Text(
                snapshot.qrJoinEnabled ? '扫描二维码加入群聊' : '群二维码已关闭',
                style: const TextStyle(color: WeChatColors.textSecondary),
              ),
            ]),
          ),
        ),
      );
}

final class GroupManagementPage extends StatelessWidget {
  const GroupManagementPage({super.key, required this.controller});
  final GroupChatInfoController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.state.snapshot!;
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('群管理')),
      child: SafeArea(
        child: ListView(children: [
          _setting('二维码进群', snapshot.qrJoinEnabled, 'qr_join_enabled'),
          _setting('进群需要群主/群管理员确认', snapshot.joinApprovalRequired,
              'join_approval_required'),
          _setting('仅群主/群管理员可修改群聊名称', snapshot.onlyManagersCanRename,
              'only_managers_can_rename'),
          if (snapshot.isOwner)
            WeChatListTile(
              title: const Text('群主管理权转让'),
              trailing: const CupertinoListTileChevron(),
            ),
          if (snapshot.isOwner)
            WeChatListTile(
              title: const Text('群管理员'),
              subtitle: Text('最多3位（${snapshot.adminIds.length}/3）'),
              trailing: const CupertinoListTileChevron(),
            ),
          if (snapshot.isOwner)
            WeChatListTile(
              title: const Text('解散该群聊',
                  style: TextStyle(color: WeChatColors.danger)),
              onTap: () => showCupertinoDialog<void>(
                context: context,
                builder: (context) => CupertinoAlertDialog(
                  title: const Text('解散该群聊'),
                  content: const Text('解散后无法恢复，请谨慎操作。'),
                  actions: [
                    CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(context),
                      child: const Text('解散'),
                    ),
                  ],
                ),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _setting(String label, bool value, String key) => WeChatListTile(
        title: Text(label),
        trailing: CupertinoSwitch(
          value: value,
          onChanged: (next) => controller.setGroupSetting(key, next),
        ),
      );
}

final class GroupMemberSearchPage extends StatefulWidget {
  const GroupMemberSearchPage({super.key, required this.snapshot});
  final GroupChatInfoSnapshot snapshot;
  @override
  State<GroupMemberSearchPage> createState() => _GroupMemberSearchPageState();
}

final class _GroupMemberSearchPageState extends State<GroupMemberSearchPage> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final members = widget.snapshot.members.where((member) =>
        member.displayName.toLowerCase().contains(query.trim().toLowerCase()));
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('群成员')),
      child: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: CupertinoSearchTextField(
              placeholder: '搜索群成员',
              onChanged: (value) => setState(() => query = value),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final member in members)
                WeChatListTile(
                  leading: UserAvatar(
                    nickname: member.displayName,
                    fallbackSeed: member.matrixUserId,
                    avatarUrl: member.avatarUrl,
                    avatarHeaders: member.avatarHeaders,
                    size: 40,
                  ),
                  title: Text(member.displayName),
                  subtitle: Text(member.matrixUserId == widget.snapshot.ownerId
                      ? '群主'
                      : widget.snapshot.adminIds.contains(member.matrixUserId)
                          ? '群管理员'
                          : ''),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

final class GroupMemberRemovalPage extends StatefulWidget {
  const GroupMemberRemovalPage({super.key, required this.controller});
  final GroupChatInfoController controller;
  @override
  State<GroupMemberRemovalPage> createState() => _GroupMemberRemovalPageState();
}

final class _GroupMemberRemovalPageState extends State<GroupMemberRemovalPage> {
  final selected = <String>{};
  @override
  Widget build(BuildContext context) {
    final snapshot = widget.controller.state.snapshot!;
    final removable = snapshot.members.where((member) =>
        member.matrixUserId != snapshot.ownerId &&
        !(snapshot.isAdmin && snapshot.adminIds.contains(member.matrixUserId)));
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        middle: const Text('移除群成员'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: selected.isEmpty ? null : _confirm,
          child: const Text('移除'),
        ),
      ),
      child: SafeArea(
        child: ListView(children: [
          for (final member in removable)
            WeChatListTile(
              title: Text(member.displayName),
              trailing: Icon(selected.contains(member.matrixUserId)
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.circle),
              onTap: () => setState(() => selected.contains(member.matrixUserId)
                  ? selected.remove(member.matrixUserId)
                  : selected.add(member.matrixUserId)),
            ),
        ]),
      ),
    );
  }

  Future<void> _confirm() async {
    final confirmed = await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('移除群成员'),
            content: Text('确定移除 ${selected.length} 位群成员吗？'),
            actions: [
              CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('移除')),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await widget.controller.removeMembers(selected.toList());
    if (mounted) Navigator.pop(context);
  }
}

final class _MemberCell extends StatelessWidget {
  const _MemberCell({super.key, required this.member, this.onTap});
  final GroupChatMember member;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Column(
        children: [
          member.client != null && member.matrixAvatarUri != null
              ? MatrixUserAvatar(
                  client: member.client!,
                  matrixAvatarUri: member.matrixAvatarUri,
                  nickname: member.displayName,
                  fallbackSeed: member.matrixUserId,
                  fallbackAvatarUrl: member.avatarUrl,
                  size: 48,
                )
              : UserAvatar(
                  nickname: member.displayName,
                  fallbackSeed: member.matrixUserId,
                  avatarUrl: member.avatarUrl,
                  avatarHeaders: member.avatarHeaders,
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
      ));
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
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
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
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
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
  const GroupChatHistoryEntry({
    required this.sender,
    required this.text,
    this.senderId = '',
    this.eventId = '',
    this.timestamp,
    this.kind = LocalChatSearchKind.text,
  });
  final String sender;
  final String text;
  final String senderId;
  final String eventId;
  final DateTime? timestamp;
  final LocalChatSearchKind kind;
}

final class GroupChatHistorySearchPage extends StatefulWidget {
  const GroupChatHistorySearchPage({
    super.key,
    required this.entries,
    this.isGroup = true,
  });
  final List<GroupChatHistoryEntry> entries;
  final bool isGroup;

  @override
  State<GroupChatHistorySearchPage> createState() =>
      _GroupChatHistorySearchPageState();
}

final class _GroupChatHistorySearchPageState
    extends State<GroupChatHistorySearchPage> {
  String query = '';
  ChatSearchCategory? category;
  DateTime? selectedDate;
  String? selectedSender;

  @override
  Widget build(BuildContext context) {
    final normalized = query.trim().toLowerCase();
    final results = widget.entries
        .where(
          (entry) =>
              (normalized.isEmpty ||
                  entry.text.toLowerCase().contains(normalized) ||
                  entry.sender.toLowerCase().contains(normalized)) &&
              (selectedSender == null || entry.sender == selectedSender) &&
              (selectedDate == null ||
                  (entry.timestamp?.year == selectedDate!.year &&
                      entry.timestamp?.month == selectedDate!.month &&
                      entry.timestamp?.day == selectedDate!.day)) &&
              switch (category) {
                ChatSearchCategory.media =>
                  entry.kind == LocalChatSearchKind.image ||
                      entry.kind == LocalChatSearchKind.video,
                ChatSearchCategory.files =>
                  entry.kind == LocalChatSearchKind.file,
                ChatSearchCategory.links =>
                  RegExp(r'https?://[^\s]+').hasMatch(entry.text),
                _ => true,
              },
        )
        .toList(growable: false);
    return WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text('查找聊天记录')),
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
            ColoredBox(
              color: WeChatColors.elevatedSurface(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 16,
                  runSpacing: 18,
                  children: [
                    for (final item in chatSearchCategories(
                      isGroup: widget.isGroup,
                    ))
                      CupertinoButton(
                        key: Key('history-category-${item.name}'),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        onPressed: () => _selectCategory(item),
                        child: SizedBox(
                          width: 82,
                          child: Column(children: [
                            Icon(_categoryIcon(item), size: 26),
                            const SizedBox(height: 7),
                            Text(_categoryLabel(item)),
                          ]),
                        ),
                      ),
                  ],
                ),
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

  Future<void> _selectCategory(ChatSearchCategory value) async {
    if (value == ChatSearchCategory.date) {
      var selected = selectedDate ?? DateTime.now();
      await showCupertinoModalPopup<void>(
        context: context,
        builder: (context) => Container(
          height: 320,
          color: WeChatColors.elevatedSurface(context),
          child: Column(children: [
            Align(
              alignment: Alignment.centerRight,
              child: CupertinoButton(
                onPressed: () {
                  setState(() {
                    category = value;
                    selectedDate = selected;
                    selectedSender = null;
                  });
                  Navigator.pop(context);
                },
                child: const Text('完成'),
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: selected,
                maximumDate: DateTime.now(),
                onDateTimeChanged: (date) => selected = date,
              ),
            ),
          ]),
        ),
      );
      return;
    }
    if (value == ChatSearchCategory.members) {
      final senders = widget.entries.map((entry) => entry.sender).toSet();
      await showCupertinoModalPopup<void>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: const Text('选择群成员'),
          actions: [
            for (final sender in senders)
              CupertinoActionSheetAction(
                onPressed: () {
                  setState(() {
                    category = value;
                    selectedSender = sender;
                    selectedDate = null;
                  });
                  Navigator.pop(context);
                },
                child: Text(sender),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ),
      );
      return;
    }
    setState(() {
      category = value;
      selectedDate = null;
      selectedSender = null;
    });
  }

  String _categoryLabel(ChatSearchCategory value) => switch (value) {
        ChatSearchCategory.date => '日期',
        ChatSearchCategory.media => '图片与视频',
        ChatSearchCategory.files => '文件',
        ChatSearchCategory.links => '链接',
        ChatSearchCategory.members => '群成员',
      };

  IconData _categoryIcon(ChatSearchCategory value) => switch (value) {
        ChatSearchCategory.date => CupertinoIcons.calendar,
        ChatSearchCategory.media => CupertinoIcons.photo_on_rectangle,
        ChatSearchCategory.files => CupertinoIcons.doc,
        ChatSearchCategory.links => CupertinoIcons.link,
        ChatSearchCategory.members => CupertinoIcons.person_2,
      };
}
