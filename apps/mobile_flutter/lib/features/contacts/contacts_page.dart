import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../matrix/matrix_e2ee_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/wechat_nav_title.dart';
import '../../ui/components/wechat_contact_index.dart';
import '../../ui/components/wechat_contact_tile.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'contact_tag_pages.dart';
import 'add_friend_profile_page.dart';
import 'friend_request_review_page.dart';
import 'contact_profile_sections.dart';
import '../search/global_search_page.dart';
import '../friendship/friend_acceptance_coordinator.dart';
import '../matrix/profile_repository.dart';
import '../matrix/direct_chat_controller.dart';

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
    this.matrix,
    required this.pendingFriendRequests,
    this.directChats,
    this.onRequestsChanged,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.onGroupChat,
    this.identityCache,
  });

  final ContactsGateway api;
  final MatrixSdkE2eeClient? matrix;
  final ValueNotifier<int> pendingFriendRequests;
  final DirectChatController? directChats;
  final VoidCallback? onRequestsChanged;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final VoidCallback? onGroupChat;
  final ProfileRepository? identityCache;

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

final class _ContactsPageState extends State<ContactsPage> {
  late Future<List<ContactSummary>> contacts;
  final scrollController = ScrollController();
  final sectionOffsets = <String, double>{};

  @override
  void initState() {
    super.initState();
    final cached = widget.identityCache?.contacts ?? const <ContactSummary>[];
    contacts = cached.isEmpty
        ? widget.api.listContacts()
        : Future.value(List.unmodifiable(cached));
    widget.identityCache?.addListener(_identityChanged);
  }

  void _identityChanged() {
    if (!mounted) return;
    setState(() {
      contacts = Future.value(
        List.unmodifiable(widget.identityCache?.contacts ?? const []),
      );
    });
  }

  void reload() {
    final next = widget.api.listContacts();
    setState(() {
      contacts = next;
    });
  }

  @override
  void dispose() {
    widget.identityCache?.removeListener(_identityChanged);
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
    return WeChatPageScaffold.navigation(
      backgroundColor: WeChatColors.tabRootPageBackground,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: WeChatColors.chatNavigationBackground,
        automaticBackgroundVisibility: false,
        enableBackgroundFilterBlur: false,
        transitionBetweenRoutes: false,
        middle: const WeChatNavTitle('通讯录'),
        trailing: businessApi == null
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: [
                CupertinoButton(
                  key: const Key('contacts-search'),
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.push(
                    context,
                    CupertinoPageRoute(
                      builder: (_) => GlobalSearchPage(
                        api: businessApi,
                        matrix: widget.matrix,
                      ),
                    ),
                  ),
                  child: const Icon(CupertinoIcons.search, size: 22),
                ),
                CupertinoButton(
                  key: const Key('contacts-more'),
                  padding: EdgeInsets.zero,
                  onPressed: () => showCupertinoModalPopup<void>(
                    context: context,
                    builder: (sheetContext) => CupertinoActionSheet(
                      actions: [
                        CupertinoActionSheetAction(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            widget.onGroupChat?.call();
                          },
                          child: const Text('发起群聊'),
                        ),
                        CupertinoActionSheetAction(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            Navigator.push(
                              context,
                              CupertinoPageRoute(
                                builder: (_) => AddFriendPage(api: businessApi),
                              ),
                            );
                          },
                          child: const Text('添加朋友'),
                        ),
                      ],
                      cancelButton: CupertinoActionSheetAction(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('取消'),
                      ),
                    ),
                  ),
                  child: const Icon(CupertinoIcons.ellipsis_circle, size: 22),
                ),
              ]),
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
                        trailing: ValueListenableBuilder<int>(
                          valueListenable: widget.pendingFriendRequests,
                          builder: (_, count, __) => count > 0
                              ? Container(
                                  key: const Key('friend-request-badge'),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2),
                                  decoration: const BoxDecoration(
                                    color: WeChatColors.danger,
                                    borderRadius:
                                        BorderRadius.all(Radius.circular(10)),
                                  ),
                                  child: Text(
                                    count > 99 ? '99+' : '$count',
                                    style: const TextStyle(
                                        color: CupertinoColors.white,
                                        fontSize: 11),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            CupertinoPageRoute(
                              builder: (_) => FriendRequestsPage(
                                api: businessApi,
                                pendingRequests: widget.pendingFriendRequests,
                                directChats: widget.directChats,
                                onRequestsChanged: widget.onRequestsChanged,
                              ),
                            ),
                          );
                        },
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
                          WeChatContactTile(
                            nickname: contact.displayName,
                            fallbackSeed: contact.username,
                            avatarUrl: contact.avatarUrl,
                            onTap: () async {
                              final changed = await Navigator.of(context,
                                      rootNavigator: true)
                                  .push<bool>(
                                CupertinoPageRoute(
                                  builder: (_) => ContactProfilePage(
                                    api: widget.api,
                                    initialContact: contact.toDetails(),
                                    onMessage: widget.onMessage,
                                    onVoice: widget.onVoice,
                                    onVideo: widget.onVideo,
                                    onContactUpdated:
                                        widget.identityCache == null
                                            ? null
                                            : (updated) => widget.identityCache!
                                                    .applyUpdatedContact(
                                                  updated.toSummary(),
                                                ),
                                  ),
                                ),
                              );
                              if (!mounted) return;
                              if (changed == true) reload();
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
                    child: WeChatContactIndex(
                        labels: ContactIndex.labels, onSelected: _jumpTo),
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

final class ContactProfilePage extends StatefulWidget {
  const ContactProfilePage({
    super.key,
    required this.api,
    required this.initialContact,
    this.onMessage,
    this.onVoice,
    this.onVideo,
    this.onContactUpdated,
  });

  final ContactsGateway api;
  final ContactDetails initialContact;
  final ContactAction? onMessage;
  final ContactAction? onVoice;
  final ContactAction? onVideo;
  final Future<void> Function(ContactDetails contact)? onContactUpdated;

  @override
  State<ContactProfilePage> createState() => _ContactProfilePageState();
}

final class _ContactProfilePageState extends State<ContactProfilePage> {
  late ContactDetails contact = widget.initialContact;

  Future<void> _openMore() async {
    final result = await Navigator.push<ContactMoreResult>(
      context,
      CupertinoPageRoute(
        builder: (_) => ContactMorePage(
          api: widget.api,
          contact: contact,
          onContactUpdated: widget.onContactUpdated,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.deleted) {
      Navigator.pop(context, true);
    } else {
      final updated = result.contact!;
      if (mounted) setState(() => contact = updated);
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
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
    this.onContactUpdated,
  });
  final ContactsGateway api;
  final ContactDetails contact;
  final Future<void> Function(ContactDetails contact)? onContactUpdated;
  @override
  State<ContactMorePage> createState() => _ContactMorePageState();
}

final class _ContactMorePageState extends State<ContactMorePage> {
  late final remark = TextEditingController(text: widget.contact.remark);
  late final tags = TextEditingController(text: widget.contact.tags.join(','));
  late String permission = widget.contact.momentsPermission;
  late ContactDetails current = widget.contact;
  bool blocked = false;
  bool saving = false;
  String? errorMessage;

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
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;

  Future<bool> _persist() async {
    if (saving) return false;
    setState(() {
      saving = true;
      errorMessage = null;
    });
    try {
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
      await widget.onContactUpdated?.call(updated);
      if (mounted) setState(() => current = updated);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() => errorMessage = '备注保存失败，请检查网络后重试');
      }
      return false;
    } finally {
      if (mounted) setState(() => saving = false);
    }
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

  Future<void> _pickTags() async {
    final updated = await Navigator.push<ContactDetails>(
      context,
      CupertinoPageRoute(
        builder: (_) => ContactTagPickerPage(
          api: widget.api,
          contact: current,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    await widget.onContactUpdated?.call(updated);
    if (!mounted) return;
    setState(() {
      current = updated;
      tags.text = updated.tags.join(',');
    });
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
    if (!value || blocked) {
      return;
    }
    if (!await _confirm('加入黑名单', '加入后将不再接收对方的好友互动。')) return;
    await widget.api.blockContact(widget.contact.userId);
    if (mounted) setState(() => blocked = true);
  }

  Future<void> _delete() async {
    try {
      if (!await _confirm('删除好友', '删除后将不再显示在你的通讯录中，且需要重新发送好友申请。')) {
        return;
      }
      await widget.api.deleteContact(widget.contact.userId);
      if (mounted) Navigator.pop(context, const ContactMoreResult.deleted());
    } catch (_) {
      if (mounted) {
        await showCupertinoDialog<void>(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('删除失败'),
            content: const Text('删除好友失败，请重试。'),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
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
              if (errorMessage != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    errorMessage!,
                    key: const Key('contact-save-error'),
                    style: const TextStyle(color: CupertinoColors.systemRed),
                  ),
                ),
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
                    onTap: _pickTags,
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
                    leading: const Icon(
                      CupertinoIcons.delete,
                      color: CupertinoColors.systemRed,
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

final class LegacyContactTagsPage extends StatefulWidget {
  const LegacyContactTagsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<LegacyContactTagsPage> createState() => _ContactTagsPageState();
}

final class ContactTagPickerPage extends StatefulWidget {
  const ContactTagPickerPage({
    super.key,
    required this.api,
    required this.contact,
  });
  final ContactsGateway api;
  final ContactDetails contact;

  @override
  State<ContactTagPickerPage> createState() => _ContactTagPickerPageState();
}

final class _ContactTagPickerPageState extends State<ContactTagPickerPage> {
  late final selected = {...widget.contact.tags};
  late Future<Map<String, dynamic>> tags = widget.api.contactTags();

  Future<void> _create() async {
    final controller = TextEditingController();
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('新建标签'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(controller: controller),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty) return;
    await widget.api.createContactTag(value);
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('标签'),
          trailing: CupertinoButton(
            padding: EdgeInsets.zero,
            child: const Text('完成'),
            onPressed: () async {
              final updated = await widget.api.updateContactDetails(
                widget.contact,
                remark: widget.contact.remark,
                tags: selected.toList(growable: false),
                momentsPermission: widget.contact.momentsPermission,
              );
              if (context.mounted) Navigator.pop(context, updated);
            },
          ),
        ),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: tags,
            builder: (_, snapshot) {
              final items = (snapshot.data?['items'] as List?) ?? const [];
              return ListView(
                children: [
                  WeChatListTile(
                    title: const Text('新建标签'),
                    leading: const Icon(CupertinoIcons.add_circled),
                    onTap: _create,
                  ),
                  for (final raw in items)
                    WeChatListTile(
                      title: Text(raw['name'].toString()),
                      trailing: Icon(
                        selected.contains(raw['name'].toString())
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.circle,
                        color: selected.contains(raw['name'].toString())
                            ? WeChatColors.brandPrimary
                            : WeChatColors.textTertiary,
                      ),
                      onTap: () => setState(() {
                        final name = raw['name'].toString();
                        selected.contains(name)
                            ? selected.remove(name)
                            : selected.add(name);
                      }),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

final class _ContactTagsPageState extends State<LegacyContactTagsPage> {
  final name = TextEditingController();
  late Future<Map<String, dynamic>> tags = widget.api.contactTags();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _rename(Map tag) async {
    final field = TextEditingController(text: tag['name'].toString());
    final value = await showCupertinoDialog<String>(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('重命名标签'),
        content: CupertinoTextField(controller: field, autofocus: true),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消')),
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(dialogContext, field.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    field.dispose();
    if (value == null || value.isEmpty) return;
    await widget.api.renameContactTag(tag['id'].toString(), value);
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  Future<void> _delete(Map tag) async {
    await widget.api.deleteContactTag(tag['id'].toString());
    if (mounted) setState(() => tags = widget.api.contactTags());
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('标签')),
        child: SafeArea(
          child: FutureBuilder<Map<String, dynamic>>(
            future: tags,
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
                          name.clear();
                          if (mounted) {
                            setState(() => tags = widget.api.contactTags());
                          }
                        },
                      ),
                    ],
                  ),
                  for (final tag in items)
                    WeChatListTile(
                      leading: const Icon(CupertinoIcons.tag),
                      title: Text(tag['name'].toString()),
                      onTap: () =>
                          _rename(Map<String, dynamic>.from(tag as Map)),
                      trailing: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () =>
                            _delete(Map<String, dynamic>.from(tag as Map)),
                        child: const Icon(CupertinoIcons.delete,
                            color: CupertinoColors.systemRed),
                      ),
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
  final AddFriendGateway api;
  @override
  State<AddFriendPage> createState() => _AddFriendState();
}

final class _AddFriendState extends State<AddFriendPage> {
  static const _minQueryLength = 2;

  final q = TextEditingController();
  Timer? _debounce;
  List items = [];
  String? hint = '输入至少 $_minQueryLength 个字符，可通过畅聊号或邮箱搜索';
  bool searching = false;

  @override
  void initState() {
    super.initState();
    q.addListener(_onChanged);
  }

  @override
  void dispose() {
    q.removeListener(_onChanged);
    _debounce?.cancel();
    q.dispose();
    super.dispose();
  }

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    final query = q.text.trim();
    if (query.length < _minQueryLength) {
      if (!mounted) return;
      setState(() {
        items = [];
        searching = false;
        hint = '输入至少 $_minQueryLength 个字符，可通过畅聊号或邮箱搜索';
      });
      return;
    }
    setState(() => searching = true);
    try {
      final result = await widget.api.searchUsers(query);
      if (!mounted) return;
      setState(() {
        items = result['items'] as List;
        searching = false;
        hint = items.isEmpty ? '未找到匹配的用户' : null;
      });
    } on BusinessApiException catch (error) {
      if (!mounted) return;
      setState(() {
        items = [];
        searching = false;
        hint = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        items = [];
        searching = false;
        hint = '搜索失败，请稍后重试';
      });
    }
  }

  void _openRequestPage(Map user) {
    // BUG 2：先看资料再决定是否添加，禁止快捷直接发送请求。
    final nickname = user['nickname']?.toString();
    Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => AddFriendProfilePage(
          api: widget.api,
          userId: user['user_id'].toString(),
          username: user['username'].toString(),
          nickname: nickname != null && nickname.isNotEmpty
              ? nickname
              : user['username'].toString(),
          relationshipState: user['relationship_state']?.toString() ?? 'NONE',
          avatarUrl: user['avatar_url']?.toString(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            automaticBackgroundVisibility: false,
            enableBackgroundFilterBlur: false,
            middle: Text('添加朋友')),
        child: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: CupertinoSearchTextField(
                controller: q,
                placeholder: '畅聊号 / 邮箱',
                onSubmitted: (_) => _search(),
              ),
            ),
            if (searching)
              const Padding(
                padding: EdgeInsets.all(12),
                child: CupertinoActivityIndicator(),
              )
            else if (hint != null)
              Padding(
                key: const Key('add-friend-hint'),
                padding: const EdgeInsets.all(16),
                child: Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    color: WeChatColors.textSecondary,
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final user in items)
                    WeChatListTile(
                      key: Key('add-friend-${user['user_id']}'),
                      onTap: () => _openRequestPage(user as Map),
                      leading: UserAvatar(
                        nickname:
                            (user['nickname']?.toString().isNotEmpty ?? false)
                                ? user['nickname'].toString()
                                : user['username'].toString(),
                        fallbackSeed: user['user_id'].toString(),
                        avatarUrl: user['avatar_url']?.toString(),
                        diagnosticSource: 'add-friend-search',
                      ),
                      title: Text(user['nickname']?.toString() ?? ''),
                      subtitle: Text('畅聊号：${user['username']}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _friendLabel(
                                user['relationship_state']?.toString()),
                            key: Key('add-friend-state-${user['user_id']}'),
                            style: const TextStyle(
                                fontSize: 13,
                                color: WeChatColors.textSecondary),
                          ),
                          const SizedBox(width: 4),
                          const CupertinoListTileChevron(),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ]),
        ),
      );
}

String _friendLabel(String? state) => switch (state) {
      'OUTGOING_PENDING' => '申请已发送',
      'FRIEND' => '已添加',
      'REUSABLE' => '重新申请',
      _ => '添加',
    };

final class FriendRequestsPage extends StatefulWidget {
  const FriendRequestsPage({
    super.key,
    required this.api,
    this.pendingRequests,
    this.directChats,
    this.onRequestsChanged,
    this.identityCache,
    this.onEstablishDirectChat,
  });
  final BusinessApiClient api;
  final ValueNotifier<int>? pendingRequests;

  /// 接受申请成功后用于立即创建双方 DM 会话（消息页即时出现入口）。
  final DirectChatController? directChats;

  /// 申请状态变化后回调（通讯录/消息页即时刷新）。
  final VoidCallback? onRequestsChanged;

  /// BUG 3：accept 成功后乐观插入好友（本地立即可见，禁止等待重启）。
  final ProfileRepository? identityCache;

  /// BUG 3：accept 成功后建立私聊并发送好友接受系统消息
  /// （matrixUserId, friendUserId, friendDisplayName）。
  final Future<void> Function(
          String matrixUserId, String friendUserId, String friendDisplayName)?
      onEstablishDirectChat;

  @override
  State<FriendRequestsPage> createState() => _FriendRequestsPageState();
}

final class _FriendRequestsPageState extends State<FriendRequestsPage> {
  late Future<Map<String, dynamic>> requests = widget.api.friendRequests();

  void _reload() => setState(() => requests = widget.api.friendRequests());

  /// BUG 2：点击申请进入"通过朋友验证"页；accept/reject 只在该页触发。
  Future<void> _openReview(Map request) async {
    final id = request['id'].toString();
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => FriendRequestReviewPage(
          request: request,
          onAccept: () => _resolve(id, true),
          onReject: () => _resolve(id, false),
        ),
      ),
    );
    if (mounted) _reload();
  }

  /// BUG 3：accept 编排（对应领域事件 friend.accepted）。
  /// 仅当用户在"通过朋友验证"页点击通过验证时才调用 accept API；
  /// 成功后：乐观插入本地好友 → 建立/取得加密私聊 → 发送好友接受
  /// 系统消息 → 会话列表刷新。任何后续步骤失败都不回滚好友关系，
  /// 禁止要求用户退出 APP 才能看到好友。
  Future<void> _resolve(String id, bool accept) async {
    if (accept) {
      await widget.api.acceptFriendRequest(id);
    } else {
      await widget.api.rejectFriendRequest(id);
    }
    final pending = widget.pendingRequests;
    if (pending != null && pending.value > 0) {
      pending.value -= 1;
    }
    if (accept) {
      final items =
          ((await widget.api.friendRequests())['items'] as List?) ?? const [];
      final request = items.whereType<Map>().firstWhere(
            (item) => item['id']?.toString() == id,
            orElse: () => const {},
          );
      await _onFriendAccepted(request);
    }
    widget.onRequestsChanged?.call();
    if (mounted) _reload();
  }

  Future<void> _onFriendAccepted(Map request) async {
    final cache = widget.identityCache;
    if (cache == null) return;
    // BUG 3 编排：乐观插入 + 私聊建立 + 好友接受系统消息。
    final coordinator = FriendAcceptanceCoordinator(
      identityCache: cache,
      establishDirectChat: widget.onEstablishDirectChat ??
          (matrixUserId, friendUserId, friendDisplayName) async {
            final directChats = widget.directChats;
            if (directChats != null) {
              try {
                await directChats.open(matrixUserId);
              } catch (_) {}
            }
          },
    );
    await coordinator.onAccepted(request);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
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
                      onTap: () => _openReview(request),
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
  const _FriendRequestTile({required this.request, required this.onTap});
  final Map request;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // BUG 2 状态机：PENDING/ACCEPTED/REJECTED/EXPIRED/CANCELLED。
    final status = request['status']?.toString() ?? 'PENDING';
    final label = switch (status) {
      'PENDING' => '接受',
      'ACCEPTED' => '已添加',
      'REJECTED' => '已拒绝',
      'EXPIRED' => '已过期',
      'CANCELLED' => '已撤销',
      _ => '已处理'
    };
    return SizedBox(
      height: 68,
      child: WeChatListTile(
        onTap: onTap,
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              key: Key('friend-request-state-${request['id']}'),
              style: TextStyle(
                fontSize: 13,
                color: status == 'PENDING'
                    ? WeChatColors.brandPrimary
                    : WeChatColors.textSecondary,
              ),
            ),
            const SizedBox(width: 4),
            const CupertinoListTileChevron(),
          ],
        ),
      ),
    );
  }
}
