import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import 'contact_models.dart';

typedef ContactAction = Future<void> Function(ContactDetails contact);

final class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.api,
    this.onMessage,
    this.onVoice,
    this.onVideo,
  });

  final ContactsGateway api;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

final class _ContactsPageState extends State<ContactsPage> {
  late Future<List<ContactSummary>> contacts = widget.api.listContacts();

  void reload() => setState(() => contacts = widget.api.listContacts());

  @override
  Widget build(BuildContext context) {
    final businessApi = widget.api is BusinessApiClient
        ? widget.api as BusinessApiClient
        : null;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('通讯录'),
        trailing: businessApi == null
            ? null
            : CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.push(
                  context,
                  CupertinoPageRoute(
                    builder: (_) => AddFriendPage(api: businessApi),
                  ),
                ),
                child: const Icon(CupertinoIcons.person_add),
              ),
      ),
      child: SafeArea(
        child: FutureBuilder<List<ContactSummary>>(
          future: contacts,
          builder: (_, snapshot) => ListView(
            children: [
              if (businessApi != null) ...[
                WeChatListTile(
                  leading: const Icon(CupertinoIcons.person_add_solid),
                  title: const Text('新的朋友'),
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => FriendRequestsPage(api: businessApi),
                    ),
                  ),
                ),
                const WeChatListTile(
                  leading: Icon(CupertinoIcons.person_3_fill),
                  title: Text('群聊'),
                ),
                WeChatListTile(
                  leading: const Icon(CupertinoIcons.tag_fill),
                  title: const Text('标签'),
                  onTap: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => ContactTagsPage(api: businessApi),
                    ),
                  ),
                ),
              ],
              for (final contact in snapshot.data ?? const <ContactSummary>[])
                WeChatListTile(
                  leading: UserAvatar(
                    nickname: contact.displayName,
                    fallbackSeed: contact.username,
                    avatarUrl: contact.avatarUrl,
                  ),
                  title: Text(contact.displayName),
                  onTap: () async {
                    await Navigator.push<bool>(
                      context,
                      CupertinoPageRoute(
                        builder: (_) => ContactProfilePage(
                          api: widget.api,
                          initialContact: contact.toDetails(),
                          onMessage: widget.onMessage,
                          onVoice: widget.onVoice,
                          onVideo: widget.onVideo,
                        ),
                      ),
                    );
                    reload();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

final class ContactProfilePage extends StatefulWidget {
  const ContactProfilePage({
    super.key,
    required this.api,
    required this.initialContact,
    this.onMessage,
    this.onVoice,
    this.onVideo,
  });

  final ContactsGateway api;
  final ContactDetails initialContact;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;

  @override
  State<ContactProfilePage> createState() => _ContactProfilePageState();
}

final class _ContactProfilePageState extends State<ContactProfilePage> {
  late ContactDetails contact = widget.initialContact;

  Future<void> _openMore() async {
    final result = await Navigator.push<ContactMoreResult>(
      context,
      CupertinoPageRoute(
        builder: (_) => ContactMorePage(api: widget.api, contact: contact),
      ),
    );
    if (!mounted || result == null) return;
    if (result.deleted) {
      Navigator.pop(context, true);
    } else {
      setState(() => contact = result.contact!);
    }
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          middle: Text(contact.displayName),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _openMore,
            child: const Icon(CupertinoIcons.ellipsis),
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: UserAvatar(
                  nickname: contact.displayName,
                  fallbackSeed: contact.username,
                  avatarUrl: contact.avatarUrl,
                  size: 88,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  contact.displayName,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ModernActionButton(
                icon: CupertinoIcons.chat_bubble_2,
                label: '消息',
                onPressed: () => widget.onMessage?.call(contact),
              ),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: CupertinoIcons.phone,
                label: '语音通话',
                onPressed: () => widget.onVoice?.call(contact),
              ),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: CupertinoIcons.video_camera,
                label: '视频通话',
                onPressed: () => widget.onVideo?.call(contact),
              ),
            ],
          ),
        ),
      );
}

final class ContactMoreResult {
  const ContactMoreResult.updated(this.contact) : deleted = false;
  const ContactMoreResult.deleted()
      : contact = null,
        deleted = true;
  final ContactDetails? contact;
  final bool deleted;
}

final class ContactMorePage extends StatefulWidget {
  const ContactMorePage({
    super.key,
    required this.api,
    required this.contact,
  });
  final ContactsGateway api;
  final ContactDetails contact;
  @override
  State<ContactMorePage> createState() => _ContactMorePageState();
}

final class _ContactMorePageState extends State<ContactMorePage> {
  late final remark = TextEditingController(text: widget.contact.remark);
  late final tags = TextEditingController(text: widget.contact.tags.join(','));
  late String permission = widget.contact.momentsPermission;

  @override
  void dispose() {
    remark.dispose();
    tags.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String content) async =>
      await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          title: Text(title),
          content: Text(content),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            CupertinoDialogAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _save() async {
    final updated = await widget.api.updateContactDetails(
      widget.contact,
      remark: remark.text.trim().isEmpty ? null : remark.text.trim(),
      tags: tags.text
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      momentsPermission: permission,
    );
    if (mounted) Navigator.pop(context, ContactMoreResult.updated(updated));
  }

  Future<void> _block() async {
    if (!await _confirm('加入黑名单', '加入后将不再接收对方的好友互动。')) return;
    await widget.api.blockContact(widget.contact.userId);
    if (mounted) {
      Navigator.pop(context, ContactMoreResult.updated(widget.contact));
    }
  }

  Future<void> _delete() async {
    if (!await _confirm('删除好友', '删除后需要重新发送好友申请。')) return;
    await widget.api.deleteContact(widget.contact.userId);
    if (mounted) Navigator.pop(context, const ContactMoreResult.deleted());
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('更多')),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CupertinoTextField(controller: remark, placeholder: '备注名'),
              const SizedBox(height: 12),
              CupertinoTextField(
                controller: tags,
                placeholder: '标签（逗号分隔）',
              ),
              CupertinoListSection.insetGrouped(
                header: const Text('朋友圈权限'),
                children: [
                  for (final item in const {
                    'DEFAULT': '默认',
                    'HIDE_MINE': '不让他看我',
                    'HIDE_THEIRS': '不看他',
                    'MUTUAL_HIDE': '互相不可见',
                  }.entries)
                    CupertinoListTile(
                      title: Text(item.value),
                      trailing: permission == item.key
                          ? const Icon(CupertinoIcons.check_mark)
                          : null,
                      onTap: () => setState(() => permission = item.key),
                    ),
                ],
              ),
              ModernActionButton(
                icon: CupertinoIcons.check_mark,
                label: '保存',
                onPressed: _save,
              ),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: CupertinoIcons.nosign,
                label: '加入黑名单',
                kind: ModernActionKind.danger,
                onPressed: _block,
              ),
              const SizedBox(height: 10),
              ModernActionButton(
                icon: CupertinoIcons.delete,
                label: '删除好友',
                kind: ModernActionKind.danger,
                onPressed: _delete,
              ),
            ],
          ),
        ),
      );
}

final class ContactTagsPage extends StatefulWidget {
  const ContactTagsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<ContactTagsPage> createState() => _ContactTagsPageState();
}

final class _ContactTagsPageState extends State<ContactTagsPage> {
  final name = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('标签')),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: widget.api.contactTags(),
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              return ListView(
                children: [
                  CupertinoListSection.insetGrouped(
                    children: [
                      CupertinoTextField(
                        controller: name,
                        placeholder: '新标签名称',
                        padding: const EdgeInsets.all(12),
                      ),
                      ModernActionButton(
                        icon: CupertinoIcons.add_circled,
                        label: '创建标签',
                        onPressed: () async {
                          await widget.api.createContactTag(name.text.trim());
                          if (mounted) setState(() {});
                        },
                      ),
                    ],
                  ),
                  for (final tag in items)
                    WeChatListTile(
                      leading: const Icon(CupertinoIcons.tag),
                      title: Text(tag['name'].toString()),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

final class AddFriendPage extends StatefulWidget {
  const AddFriendPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<AddFriendPage> createState() => _AddFriendState();
}

final class _AddFriendState extends State<AddFriendPage> {
  final q = TextEditingController();
  List items = [];
  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('添加朋友')),
        child: SafeArea(
          child: ListView(
            children: [
              CupertinoSearchTextField(
                controller: q,
                onSubmitted: (value) async {
                  final result = await widget.api.searchUsers(value);
                  if (mounted) setState(() => items = result['items'] as List);
                },
              ),
              for (final user in items)
                WeChatListTile(
                  title: Text(user['username'].toString()),
                  trailing: ModernActionButton(
                    icon: CupertinoIcons.person_add,
                    label: '添加',
                    onPressed: () =>
                        widget.api.requestFriend(user['user_id'].toString()),
                  ),
                ),
            ],
          ),
        ),
      );
}

final class FriendRequestsPage extends StatelessWidget {
  const FriendRequestsPage({super.key, required this.api});
  final BusinessApiClient api;

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: const CupertinoNavigationBar(middle: Text('新的朋友')),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: api.friendRequests(),
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              return ListView(
                children: [
                  for (final request in items)
                    WeChatListTile(
                      title: Text(request['username']?.toString() ?? ''),
                      subtitle: Text(request['message']?.toString() ?? ''),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ModernActionButton(
                            icon: CupertinoIcons.clear,
                            label: '拒绝',
                            kind: ModernActionKind.danger,
                            onPressed: () => api.rejectFriendRequest(
                              request['id'].toString(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ModernActionButton(
                            icon: CupertinoIcons.check_mark,
                            label: '接受',
                            onPressed: () => api.acceptFriendRequest(
                              request['id'].toString(),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}
