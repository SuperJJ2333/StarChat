import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../core/business_api_client.dart';
import '../../ui/components/modern_action_button.dart';
import '../../ui/components/wechat_list_tile.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/moments/moment_warning_banner.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import '../contacts/contact_tag_models.dart';
import '../matrix/profile_repository.dart';
import 'moment_visibility_selection.dart';

final class MomentVisibilityPeoplePage extends StatefulWidget {
  const MomentVisibilityPeoplePage({
    super.key,
    required this.api,
    required this.mode,
    required this.initialSelection,
    this.identityCache,
  });

  /// 本地联系人投影：先用它渲染「朋友」页签（断网也能选人），随后后台刷新。
  final ProfileRepository? identityCache;

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

  /// 本地优先：先用已水合的联系人投影渲染「朋友」页签，再后台刷新。
  List<ContactSummary> _contacts = const [];
  List<ContactTagSummary> _allTags = const [];
  bool _loading = false;
  Object? _error;
  int _generation = 0;
  bool _disposed = false;
  String _tab = '标签';
  String _query = '';

  @override
  void initState() {
    super.initState();
    final cache = widget.identityCache;
    if (cache != null) _contacts = cache.contacts;
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
    try {
      final results = await Future.wait<Object>([
        widget.api.listContacts(),
        widget.api.contactTags(),
      ]);
      if (_disposed || generation != _generation) return;
      final contacts = results[0] as List<ContactSummary>;
      final tagJson = results[1] as Map<String, dynamic>;
      final allTags = ((tagJson['items'] as List?) ?? const [])
          .map((raw) => ContactTagSummary.fromJson(
                Map<String, dynamic>.from(raw as Map),
              ))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
        _allTags = allTags;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (_disposed || generation != _generation) return;
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  MomentVisibilitySelection get _selection => MomentVisibilitySelection(
        visibility: widget.mode,
        userIds: Set.unmodifiable(users),
        tagIds: Set.unmodifiable(tags),
      );

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        backgroundColor: WeChatColors.pageBackground(context),
        navigationBar: CupertinoNavigationBar(
          backgroundColor: WeChatColors.navigationBackground(context),
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
          child: Builder(builder: (context) {
            // 本地优先 / 失败不覆盖：有本地联系人或本地标签就先渲染，
            // 只有"什么都没有且确实失败"才显示整页错误。
            if (_contacts.isEmpty && _allTags.isEmpty) {
              if (_loading) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (_error != null) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const MomentWarningBanner(message: '标签或朋友加载失败，请检查网络后重试'),
                      const SizedBox(height: 12),
                      ModernActionButton(
                        icon: CupertinoIcons.refresh,
                        label: '重试',
                        onPressed: () => unawaited(_load()),
                      ),
                    ],
                  ),
                );
              }
            }
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
                  color: WeChatColors.elevatedSurface(context),
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
                        ? _tagRows(_allTags)
                        : _contactRows(_contacts),
                  ),
                ),
              ],
            );
          }),
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
                    ? WeChatColors.resolveTextPrimary(context)
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
            key: Key('visibility-friend-${contact.userId}'),
            // 自定义头像：与全 App 一致的 UserAvatar 渲染与缓存机制。
            leading: UserAvatar(
              nickname: contact.displayName,
              fallbackSeed: contact.userId,
              avatarUrl: contact.avatarUrl,
              size: 36,
            ),
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
