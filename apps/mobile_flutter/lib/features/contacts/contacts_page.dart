import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'contact_profile_sections.dart';

typedef ContactAction = Future<void> Function(ContactDetails contact);

abstract final class ContactIndex {
  static const alphabet = <String>[
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L',
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
  ];
  static const labels = <String>['★', ...alphabet, '#'];
}

final class ContactsPage extends StatefulWidget {
  const ContactsPage({
    super.key,
    required this.api,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.onGroupChat,
  });

  final ContactsGateway api;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final VoidCallback? onGroupChat;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

final class _ContactsPageState extends State<ContactsPage> {
  late Future<List<ContactSummary>> contacts = widget.api.listContacts();
  final scrollController = ScrollController();
  final sectionOffsets = <String, double>{};

  void reload() {
    final next = widget.api.listContacts();
    setState(() {
      contacts = next;
    });
  }

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }

  String _indexOf(ContactSummary contact) {
    if (contact.isStarred) return '★';
    for (final candidate in [contact.displayName, contact.username]) {
      if (candidate.isEmpty) continue;
      final initial = candidate.characters.first.toUpperCase();
      if (ContactIndex.alphabet.contains(initial)) return initial;
    }
    return '#';
  }

  Map<String, List<ContactSummary>> _groupContacts(
    List<ContactSummary> values,
  ) {
    final result = <String, List<ContactSummary>>{};
    for (final contact in values) {
      (result[_indexOf(contact)] ??= []).add(contact);
    }
    for (final contacts in result.values) {
      contacts.sort(
        (a, b) => a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            ),
      );
    }
    return result;
  }

  Future<void> _jumpTo(String label) async {
    final offset = sectionOffsets[label];
    if (offset == null || !scrollController.hasClients) return;
    await scrollController.animateTo(
      offset.clamp(0, scrollController.position.maxScrollExtent).toDouble(),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final businessApi = widget.api is BusinessApiClient
        ? widget.api as BusinessApiClient
        : null;
    return CupertinoPageScaffold(
      backgroundColor: WeChatColors.tabRootPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
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
          builder: (_, snapshot) {
            final grouped = _groupContacts(
              snapshot.data ?? const <ContactSummary>[],
            );
            var sectionOffset = businessApi == null ? 0.0 : 56.0 * 3;
            sectionOffsets.clear();
            for (final label in ContactIndex.labels) {
              final contacts = grouped[label];
              if (contacts == null || contacts.isEmpty) continue;
              sectionOffsets[label] = sectionOffset;
              sectionOffset += 25 + contacts.length * 56;
            }
            return Stack(
              children: [
                ListView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  padding: const EdgeInsets.only(right: 20),
                  children: [
                    if (businessApi != null) ...[
                      WeChatListTile(
                        leading: const Icon(CupertinoIcons.person_add_solid),
                        title: const Text('新的朋友'),
                        onTap: () => Navigator.push(
                          context,
                          CupertinoPageRoute(
                            builder: (_) =>
                                FriendRequestsPage(api: businessApi),
                          ),
                        ),
                      ),
                      WeChatListTile(
                        leading: const Icon(CupertinoIcons.person_3_fill),
                        title: const Text('群聊'),
                        onTap: widget.onGroupChat,
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
                    for (final label in ContactIndex.labels)
                      if (grouped[label]?.isNotEmpty ?? false) ...[
                        _ContactSectionHeader(
                          label: label == '★' ? '星标好友' : label,
                        ),
                        for (final contact in grouped[label]!)
                          WeChatListTile(
                            leading: UserAvatar(
                              nickname: contact.displayName,
                              fallbackSeed: contact.username,
                              avatarUrl: contact.avatarUrl,
                            ),
                            title: Text(contact.displayName),
                            onTap: () async {
                              await Navigator.of(context, rootNavigator: true)
                                  .push<bool>(
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
                              if (mounted) setState(() {});
                            },
                          ),
                      ],
                  ],
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  bottom: 0,
                  width: 20,
                  child: AnimatedBuilder(
                    animation: scrollController,
                    child: _ContactLetterIndex(onTap: _jumpTo),
                    builder: (_, child) {
                      final pullDown = scrollController.hasClients
                          ? (-scrollController.offset)
                              .clamp(0.0, double.infinity)
                          : 0.0;
                      return Transform.translate(
                        offset: Offset(0, pullDown),
                        child: child,
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

final class _ContactSectionHeader extends StatelessWidget {
  const _ContactSectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: CupertinoTheme.of(context).scaffoldBackgroundColor,
        child: SizedBox(
          key: Key('contact-section-$label'),
          height: 25,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              label,
              style: const TextStyle(
                color: WeChatColors.textSecondary,
                fontSize: WeChatTypography.caption,
              ),
            ),
          ),
        ),
      );
}

final class _ContactLetterIndex extends StatelessWidget {
  const _ContactLetterIndex({required this.onTap});
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) => ColoredBox(
        key: const Key('contact-index'),
        color: WeChatColors.elevatedSurface(context),
        child: Column(
          children: [
            for (final label in ContactIndex.labels)
              Expanded(
                child: CupertinoButton(
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  onPressed: () => onTap(label),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: WeChatColors.textSecondary,
                      fontSize: WeChatTypography.badge,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
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
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('好友资料'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _openMore,
            child: const Icon(CupertinoIcons.ellipsis),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              FriendIdentityCard(contact: contact),
              if (contact.momentsPermission == 'HAS_VISIBLE_MOMENTS')
                const FriendMomentsPreview(),
              FriendActionColumn(
                onMessage: widget.onMessage == null
                    ? null
                    : () => widget.onMessage!(contact),
                onVoice: widget.onVoice == null
                    ? null
                    : () => widget.onVoice!(contact),
                onVideo: widget.onVideo == null
                    ? null
                    : () => widget.onVideo!(contact),
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
  late ContactDetails current = widget.contact;
  bool blocked = false;

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

  Future<void> _persist() async {
    final updated = await widget.api.updateContactDetails(
      current,
      remark: remark.text.trim().isEmpty ? null : remark.text.trim(),
      tags: tags.text
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false),
      momentsPermission: permission,
    );
    if (mounted) setState(() => current = updated);
  }

  Future<void> _editText(
    String title,
    TextEditingController controller,
  ) async {
    final accepted = await showCupertinoDialog<bool>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: Text(title),
            content: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: CupertinoTextField(controller: controller),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('保存'),
              ),
            ],
          ),
        ) ??
        false;
    if (accepted) await _persist();
  }

  Future<void> _choosePermission() async {
    final selected = await showCupertinoModalPopup<String>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        title: const Text('朋友圈权限'),
        actions: [
          for (final item in const {
            'DEFAULT': '全部可见',
            'HIDE_MINE': '不让他看我',
            'HIDE_THEIRS': '不看他',
            'MUTUAL_HIDE': '互相不可见',
          }.entries)
            CupertinoActionSheetAction(
              onPressed: () => Navigator.pop(sheetContext, item.key),
              child: Text(item.value),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    );
    if (selected == null || selected == permission) return;
    setState(() => permission = selected);
    await _persist();
  }

  Future<void> _setBlocked(bool value) async {
    if (!value || blocked) return;
    if (!await _confirm('加入黑名单', '加入后将不再接收对方的好友互动。')) return;
    await widget.api.blockContact(widget.contact.userId);
    if (mounted) setState(() => blocked = true);
  }

  Future<void> _delete() async {
    if (!await _confirm('删除好友', '删除后需要重新发送好友申请。')) return;
    await widget.api.deleteContact(widget.contact.userId);
    if (mounted) Navigator.pop(context, const ContactMoreResult.deleted());
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('好友设置'),
          leading: CupertinoNavigationBarBackButton(
            onPressed: () => Navigator.pop(
              context,
              ContactMoreResult.updated(current),
            ),
          ),
        ),
        child: SafeArea(
          child: ListView(
            children: [
              CupertinoListSection(
                margin: const EdgeInsets.only(top: 12),
                children: [
                  CupertinoListTile(
                    title: const Text('备注'),
                    additionalInfo: Text(remark.text),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _editText('设置备注', remark),
                  ),
                  CupertinoListTile(
                    title: const Text('标签'),
                    additionalInfo: Text(tags.text),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _editText('设置标签', tags),
                  ),
                  CupertinoListTile(
                    title: const Text('朋友圈权限'),
                    additionalInfo: Text(
                      permission == 'DEFAULT' ? '全部可见' : '已限制',
                    ),
                    trailing: const CupertinoListTileChevron(),
                    onTap: _choosePermission,
                  ),
                  CupertinoListTile(
                    title: const Text('黑名单'),
                    trailing: CupertinoSwitch(
                      value: blocked,
                      onChanged: _setBlocked,
                    ),
                  ),
                ],
              ),
              CupertinoListSection(
                margin: const EdgeInsets.only(top: 12),
                children: [
                  CupertinoListTile(
                    title: const Text(
                      '删除好友',
                      style: TextStyle(color: CupertinoColors.systemRed),
                    ),
                    onTap: _delete,
                  ),
                ],
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
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('标签')),
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
  String? submittingUserId;
  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  Future<void> _request(Map user) async {
    final userId = user['user_id'].toString();
    final state = user['relationship_state']?.toString() ?? 'NONE';
    if (state == 'OUTGOING_PENDING' || state == 'FRIEND') {
      _message('不能重复发送好友请求');
      return;
    }
    setState(() => submittingUserId = userId);
    try {
      await widget.api.requestFriend(userId);
      if (!mounted) return;
      setState(() {
        user['relationship_state'] = 'OUTGOING_PENDING';
        submittingUserId = null;
      });
    } on BusinessApiException catch (error) {
      if (mounted) {
        _message(
          error.code == 'FRIEND_REQUEST_DUPLICATE'
              ? '不能重复发送好友请求'
              : error.message,
        );
      }
    } finally {
      if (mounted && submittingUserId == userId) {
        setState(() => submittingUserId = null);
      }
    }
  }

  void _message(String text) => showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          content: Text(text),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('添加朋友')),
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
                  subtitle: Text('畅聊号：${user['username']}'),
                  trailing: ModernActionButton(
                    icon: _friendIcon(user['relationship_state']?.toString()),
                    label: _friendLabel(user['relationship_state']?.toString()),
                    loading: submittingUserId == user['user_id'].toString(),
                    onPressed: submittingUserId == null
                        ? () => _request(user as Map)
                        : null,
                  ),
                ),
            ],
          ),
        ),
      );
}

String _friendLabel(String? state) => switch (state) {
      'OUTGOING_PENDING' => '申请已发送',
      'FRIEND' => '已添加',
      'REUSABLE' => '重新申请',
      _ => '添加',
    };

IconData _friendIcon(String? state) =>
    state == 'FRIEND' ? CupertinoIcons.check_mark : CupertinoIcons.person_add;

final class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({super.key, required this.api});
  final BusinessApiClient api;

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

final class _FriendRequestsPageState extends State<FriendRequestsPage> {
  late Future<Map<String, dynamic>> requests = widget.api.friendRequests();

  void _reload() => setState(() => requests = widget.api.friendRequests());

  Future<void> _resolve(String id, bool accept) async {
    if (accept) {
      await widget.api.acceptFriendRequest(id);
    } else {
      await widget.api.rejectFriendRequest(id);
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
            backgroundColor: WeChatColors.chatNavigationBackground,
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('新的朋友')),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: requests,
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              return ListView(
                children: [
                  for (final request in items)
                    _FriendRequestTile(
                      request: request as Map,
                      onAccept: () => _resolve(request['id'].toString(), true),
                      onReject: () => _resolve(request['id'].toString(), false),
                    ),
                  if (items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: WeChatSpacing.xxl),
                      child: Center(child: Text('暂无新的朋友')),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

final class _FriendRequestTile extends StatelessWidget {
  const _FriendRequestTile(
      {required this.request, required this.onAccept, required this.onReject});
  final Map request;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final status = request['status']?.toString() ?? 'PENDING';
    final label = switch (status) {
      'PENDING' => '接受',
      'ACCEPTED' => '已添加',
      'EXPIRED' => '已过期',
      _ => '已拒绝'
    };
    return GestureDetector(
      onLongPress: status == 'PENDING' ? onReject : null,
      child: SizedBox(
        height: 68,
        child: WeChatListTile(
          leading: UserAvatar(
              nickname: request['nickname']?.toString() ??
                  request['username']?.toString() ??
                  '',
              fallbackSeed: request['username']?.toString() ?? '',
              avatarUrl: request['avatar_url']?.toString()),
          title: Text(request['nickname']?.toString() ??
              request['username']?.toString() ??
              ''),
          subtitle: Text(request['message']?.toString().isNotEmpty == true
              ? request['message'].toString()
              : '请求添加你为好友'),
          trailing: SizedBox(
              width: 64,
              height: 32,
              child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: status == 'PENDING' ? onAccept : null,
                  child: Text(label))),
        ),
      ),
    );
  }
}
