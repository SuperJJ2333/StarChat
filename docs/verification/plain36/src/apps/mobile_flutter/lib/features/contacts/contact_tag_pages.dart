import 'package:flutter/cupertino.dart';

import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import 'contact_models.dart';
import 'contact_tag_models.dart';

final class ContactTagsPage extends StatefulWidget {
  const ContactTagsPage({super.key, required this.api});
  final ContactsGateway api;
  @override
  State<ContactTagsPage> createState() => _ContactTagsPageState();
}

final class _ContactTagsPageState extends State<ContactTagsPage> {
  late Future<List<ContactTagSummary>> tags = _load();
  bool editing = false;
  final selected = <String>{};
  Future<List<ContactTagSummary>> _load() async => sortContactTags(
        ((await widget.api.contactTags())['items'] as List? ?? const []).map(
            (raw) => ContactTagSummary.fromJson(
                Map<String, dynamic>.from(raw as Map))),
      );
  void reload() => setState(() => tags = _load());
  Future<void> _newTag() async {
    final input = TextEditingController();
    final name = await showCupertinoDialog<String>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
                title: const Text('设置标签名称'),
                content: CupertinoTextField(controller: input, autofocus: true),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  CupertinoDialogAction(
                      onPressed: () =>
                          Navigator.pop(context, input.text.trim()),
                      child: const Text('确定'))
                ]));
    input.dispose();
    if (name?.isNotEmpty == true) {
      await widget.api.createContactTag(name!);
      reload();
    }
  }

  Future<void> _deleteSelected() async {
    if (selected.isEmpty) return;
    final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
                title: const Text('删除标签'),
                content: const Text('删除后不可恢复，是否继续？'),
                actions: [
                  CupertinoDialogAction(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  CupertinoDialogAction(
                      isDestructiveAction: true,
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'))
                ]));
    if (confirmed == true) {
      await widget.api.deleteContactTags(selected.toList(growable: false));
      selected.clear();
      setState(() => editing = false);
      reload();
    }
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: const Text('通讯录标签')),
      child: SafeArea(
          child: Column(children: [
        Expanded(
            child: FutureBuilder<List<ContactTagSummary>>(
                future: tags,
                builder: (_, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  final items = snapshot.data!;
                  if (items.isEmpty) return const Center(child: Text('暂无标签'));
                  return ListView(children: [
                    for (final tag in items)
                      WeChatListTile(
                          leading: editing
                              ? Icon(
                                  selected.contains(tag.id)
                                      ? CupertinoIcons.check_mark_circled_solid
                                      : CupertinoIcons.circle,
                                  color: WeChatColors.brandPrimary)
                              : const Icon(CupertinoIcons.tag),
                          title: Text(tag.name),
                          subtitle: Text('${tag.friendCount} 位朋友'),
                          onTap: () {
                            if (editing) {
                              setState(() => selected.contains(tag.id)
                                  ? selected.remove(tag.id)
                                  : selected.add(tag.id));
                            } else {
                              Navigator.push(
                                  context,
                                  CupertinoPageRoute(
                                      builder: (_) => ContactTagMembersPage(
                                          api: widget.api,
                                          tag: tag))).then((_) => reload());
                            }
                          })
                  ]);
                })),
        SizedBox(
            height: 56,
            child: Row(children: [
              Expanded(
                  child: CupertinoButton(
                      key: const Key('contact-tags-new'),
                      onPressed: editing ? null : _newTag,
                      child: const Text('新建'))),
              Expanded(
                  child: CupertinoButton(
                      key: const Key('contact-tags-edit'),
                      onPressed: editing
                          ? _deleteSelected
                          : () => setState(() => editing = true),
                      child: Text(editing ? '删除' : '编辑',
                          style: TextStyle(
                              color:
                                  editing ? CupertinoColors.systemRed : null))))
            ]))
      ])));
}

final class ContactTagMembersPage extends StatefulWidget {
  const ContactTagMembersPage(
      {super.key, required this.api, required this.tag});
  final ContactsGateway api;
  final ContactTagSummary tag;
  @override
  State<ContactTagMembersPage> createState() => _ContactTagMembersPageState();
}

final class _ContactTagMembersPageState extends State<ContactTagMembersPage> {
  late Future<List<ContactSummary>> contacts = widget.api.listContacts();
  final query = TextEditingController();
  bool removing = false;
  final selected = <String>{};
  void reload() => setState(() => contacts = widget.api.listContacts());
  Future<void> _remove() async {
    if (!removing) {
      setState(() => removing = true);
      return;
    }
    final all = await widget.api.listContacts();
    for (final c in contactsForTag(all, widget.tag.name)
        .where((c) => selected.contains(c.userId))) {
      await widget.api.updateContactDetails(c.toDetails(),
          remark: c.remark,
          tags: removeTag(c.tags, widget.tag.name),
          momentsPermission: c.momentsPermission);
    }
    selected.clear();
    setState(() => removing = false);
    reload();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          middle: Text(widget.tag.name),
          trailing: CupertinoButton(
              key: const Key('tag-members-more'),
              padding: EdgeInsets.zero,
              onPressed: () => showCupertinoModalPopup(
                  context: context,
                  builder: (context) => CupertinoActionSheet(
                          actions: [
                            CupertinoActionSheetAction(
                                onPressed: () async {
                                  Navigator.pop(context);
                                  final field = TextEditingController(
                                      text: widget.tag.name);
                                  final name = await showCupertinoDialog<
                                          String>(
                                      context: context,
                                      builder: (c) => CupertinoAlertDialog(
                                              title: const Text('更改标签名称'),
                                              content: CupertinoTextField(
                                                  controller: field),
                                              actions: [
                                                CupertinoDialogAction(
                                                    onPressed: () =>
                                                        Navigator.pop(c),
                                                    child: const Text('取消')),
                                                CupertinoDialogAction(
                                                    onPressed: () =>
                                                        Navigator.pop(c,
                                                            field.text.trim()),
                                                    child: const Text('确定'))
                                              ]));
                                  if (name?.isNotEmpty == true) {
                                    await widget.api
                                        .renameContactTag(widget.tag.id, name!);
                                    if (context.mounted) {
                                      Navigator.pop(context, true);
                                    }
                                  }
                                },
                                child: const Text('更改标签名称')),
                            CupertinoActionSheetAction(
                                isDestructiveAction: true,
                                onPressed: () async {
                                  Navigator.pop(context);
                                  final yes = await showCupertinoDialog<bool>(
                                      context: context,
                                      builder: (c) => CupertinoAlertDialog(
                                              title: const Text('删除标签'),
                                              content:
                                                  const Text('删除后不可恢复，是否继续？'),
                                              actions: [
                                                CupertinoDialogAction(
                                                    onPressed: () =>
                                                        Navigator.pop(c, false),
                                                    child: const Text('取消')),
                                                CupertinoDialogAction(
                                                    isDestructiveAction: true,
                                                    onPressed: () =>
                                                        Navigator.pop(c, true),
                                                    child: const Text('删除'))
                                              ]));
                                  if (yes == true) {
                                    await widget.api
                                        .deleteContactTag(widget.tag.id);
                                    if (context.mounted) {
                                      Navigator.pop(context, true);
                                    }
                                  }
                                },
                                child: const Text('删除标签'))
                          ],
                          cancelButton: CupertinoActionSheetAction(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('取消')))),
              child: const Icon(CupertinoIcons.ellipsis))),
      child: SafeArea(
          child: Column(children: [
        CupertinoSearchTextField(
            key: const Key('tag-members-search'),
            controller: query,
            onChanged: (_) => setState(() {})),
        Expanded(
            child: FutureBuilder<List<ContactSummary>>(
                future: contacts,
                builder: (_, snapshot) {
                  final items =
                      contactsForTag(snapshot.data ?? const [], widget.tag.name)
                          .where((c) => c.displayName
                              .toLowerCase()
                              .contains(query.text.toLowerCase()))
                          .toList();
                  return ListView(children: [
                    for (final c in items)
                      WeChatListTile(
                          title: Text(c.displayName),
                          trailing: removing
                              ? Icon(selected.contains(c.userId)
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.circle)
                              : null,
                          onTap: removing
                              ? () => setState(() => selected.contains(c.userId)
                                  ? selected.remove(c.userId)
                                  : selected.add(c.userId))
                              : null)
                  ]);
                })),
        Row(children: [
          Expanded(
              child: CupertinoButton(
                  onPressed: () => Navigator.push(
                      context,
                      CupertinoPageRoute(
                          builder: (_) => ContactTagFriendPickerPage(
                              api: widget.api,
                              tag: widget.tag))).then((_) => reload()),
                  child: const Text('添加'))),
          Expanded(
              child:
                  CupertinoButton(onPressed: _remove, child: const Text('移出')))
        ])
      ])));
}

final class ContactTagFriendPickerPage extends StatefulWidget {
  const ContactTagFriendPickerPage(
      {super.key, required this.api, required this.tag});
  final ContactsGateway api;
  final ContactTagSummary tag;
  @override
  State<ContactTagFriendPickerPage> createState() => _PickerState();
}

final class _PickerState extends State<ContactTagFriendPickerPage> {
  late Future<List<ContactSummary>> contacts = widget.api.listContacts();
  final query = TextEditingController();
  final selected = <String>{};
  Future<void> add() async {
    final all = await widget.api.listContacts();
    for (final c in all.where((c) => selected.contains(c.userId))) {
      await widget.api.updateContactDetails(c.toDetails(),
          remark: c.remark,
          tags: mergeTag(c.tags, widget.tag.name),
          momentsPermission: c.momentsPermission);
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
      navigationBar: CupertinoNavigationBar(
          middle: const Text('选择朋友'),
          trailing: CupertinoButton(
              onPressed: selected.isEmpty ? null : add,
              child: const Text('完成'))),
      child: SafeArea(
          child: Column(children: [
        CupertinoSearchTextField(
            controller: query, onChanged: (_) => setState(() {})),
        WeChatListTile(title: const Text('导入群聊中的朋友'), onTap: () {}),
        WeChatListTile(title: const Text('导入标签中的朋友'), onTap: () {}),
        Expanded(
            child: FutureBuilder<List<ContactSummary>>(
                future: contacts,
                builder: (_, s) {
                  final items = (s.data ?? const [])
                      .where((c) =>
                          !c.tags.contains(widget.tag.name) &&
                          c.displayName
                              .toLowerCase()
                              .contains(query.text.toLowerCase()))
                      .toList()
                    ..sort((a, b) => a.displayName
                        .toLowerCase()
                        .compareTo(b.displayName.toLowerCase()));
                  return ListView(children: [
                    for (final c in items)
                      WeChatListTile(
                          title: Text(c.displayName),
                          trailing: Icon(selected.contains(c.userId)
                              ? CupertinoIcons.check_mark_circled_solid
                              : CupertinoIcons.circle),
                          onTap: () => setState(() =>
                              selected.contains(c.userId)
                                  ? selected.remove(c.userId)
                                  : selected.add(c.userId)))
                  ]);
                }))
      ])));
}
