import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import '../contacts/contact_tag_models.dart';
import 'moment_visibility_selection.dart';

final class MomentVisibilityPeoplePage extends StatefulWidget {
  const MomentVisibilityPeoplePage({
    super.key,
    required this.api,
    required this.mode,
    required this.initialSelection,
  });

  final BusinessApiClient api;
  final String mode;
  final MomentVisibilitySelection initialSelection;

  @override
  State<MomentVisibilityPeoplePage> createState() =>
      _MomentVisibilityPeoplePageState();
}

final class _MomentVisibilityPeoplePageState
    extends State<MomentVisibilityPeoplePage> {
  late final Set<String> users = {...widget.initialSelection.userIds};
  late final Set<String> tags = {...widget.initialSelection.tagIds};
  late Future<List<Object>> _data = _load();
  String _tab = '标签';
  String _query = '';

  Future<List<Object>> _load() async => Future.wait<Object>([
        widget.api.listContacts(),
        widget.api.contactTags(),
      ]);

  MomentVisibilitySelection get _selection => MomentVisibilitySelection(
        visibility: widget.mode,
        userIds: Set.unmodifiable(users),
        tagIds: Set.unmodifiable(tags),
      );

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.tabRootPageBackground,
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.chatNavigationBackground,
          automaticBackgroundVisibility: false,
          enableBackgroundFilterBlur: false,
          middle: Text(widget.mode == 'INCLUDE' ? '只给谁看' : '不给谁看'),
          trailing: CupertinoButton(
            key: const Key('visibility-people-complete'),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context, _selection),
            child: Text('完成(${_selection.selectedCount})'),
          ),
        ),
        child: SafeArea(
          child: FutureBuilder<List<Object>>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('标签或朋友加载失败，请检查网络后重试'),
                      const SizedBox(height: 12),
                      ModernActionButton(
                        icon: CupertinoIcons.refresh,
                        label: '重试',
                        onPressed: () => setState(() => _data = _load()),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CupertinoActivityIndicator());
              }
              final contacts = snapshot.data![0] as List<ContactSummary>;
              final tagJson = snapshot.data![1] as Map<String, dynamic>;
              final allTags = ((tagJson['items'] as List?) ?? const [])
                  .map((raw) => ContactTagSummary.fromJson(
                        Map<String, dynamic>.from(raw as Map),
                      ))
                  .toList(growable: false);
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: CupertinoSearchTextField(
                      placeholder: '搜索',
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                  Container(
                    color: CupertinoColors.white,
                    child: Row(
                      children: [
                        _tabButton('标签'),
                        _tabButton('朋友'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: _tab == '标签'
                          ? _tagRows(allTags)
                          : _contactRows(contacts),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );

  Widget _tabButton(String label) {
    final selected = _tab == label;
    return Expanded(
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 12),
        onPressed: () => setState(() => _tab = label),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? WeChatColors.lightTextPrimary
                    : WeChatColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              height: 2,
              color: selected
                  ? WeChatColors.brandPrimary
                  : CupertinoColors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tagRows(List<ContactTagSummary> values) {
    final query = _query.trim().toLowerCase();
    return [
      for (final tag in values)
        if (query.isEmpty || tag.name.toLowerCase().contains(query))
          WeChatListTile(
            title: Text(tag.name),
            subtitle: Text('${tag.friendCount} 位朋友'),
            trailing: _check(tags.contains(tag.id)),
            onTap: () => setState(() {
              tags.contains(tag.id) ? tags.remove(tag.id) : tags.add(tag.id);
            }),
          ),
    ];
  }

  List<Widget> _contactRows(List<ContactSummary> values) {
    final query = _query.trim().toLowerCase();
    return [
      for (final contact in values)
        if (query.isEmpty ||
            contact.displayName.toLowerCase().contains(query) ||
            contact.nickname?.toLowerCase().contains(query) == true)
          WeChatListTile(
            title: Text(contact.displayName),
            subtitle: contact.remark?.trim().isNotEmpty == true &&
                    contact.nickname?.trim().isNotEmpty == true
                ? Text(contact.nickname!.trim())
                : null,
            trailing: _check(users.contains(contact.userId)),
            onTap: () => setState(() {
              users.contains(contact.userId)
                  ? users.remove(contact.userId)
                  : users.add(contact.userId);
            }),
          ),
    ];
  }

  Widget _check(bool checked) => Icon(
        checked
            ? CupertinoIcons.check_mark_circled_solid
            : CupertinoIcons.circle,
        color: checked ? WeChatColors.brandPrimary : WeChatColors.textTertiary,
      );
}
