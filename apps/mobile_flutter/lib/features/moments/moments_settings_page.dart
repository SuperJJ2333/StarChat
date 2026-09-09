import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import 'moments_privacy_changes.dart';

class MomentsSettingsPage extends StatefulWidget {
  const MomentsSettingsPage({super.key, required this.api});
  final BusinessApiClient api;
  @override
  State<MomentsSettingsPage> createState() => _MomentsSettingsState();
}

class _MomentsSettingsState extends State<MomentsSettingsPage> {
  String _range = 'ALL';
  bool _personalized = true, _entry = true, _loading = true, _saving = false;
  List<String> _excluded = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.momentsPreferences();
      if (!mounted) return;
      setState(() {
        _range = r['history_range'] as String? ?? 'ALL';
        _personalized = r['personalized_recommendations'] != false;
        _entry = r['profile_entry_enabled'] != false;
        _excluded = List<String>.from(r['excluded_user_ids'] ?? []);
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '权限加载失败，请重试');
    }
  }

  Future<void> _save() async {
    if (_loading || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.updateMomentsPreferences(
          historyRange: _range,
          personalized: _personalized,
          profileEntryEnabled: _entry,
          excludedUserIds: _excluded);
      momentsPrivacyChanges.changed();
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _choosePeople() async {
    final selected = await Navigator.push<List<String>>(
        context,
        CupertinoPageRoute(
            builder: (_) =>
                _ExcludedPeoplePage(api: widget.api, initial: _excluded)));
    if (!mounted || selected == null) return;
    setState(() => _excluded = selected);
    await _save();
  }

  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            middle: const Text('朋友圈权限'),
            trailing: _saving ? const CupertinoActivityIndicator() : null),
        child: SafeArea(
            child: ListView(children: [
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Text(_error!,
                      style: const TextStyle(color: CupertinoColors.systemRed)),
                  CupertinoButton(
                      key: const Key('moments-privacy-retry'),
                      onPressed: _loading ? _load : _save,
                      child: const Text('重试')),
                ])),
          if (_loading && _error == null)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CupertinoActivityIndicator())),
          if (!_loading) ...[
            CupertinoListSection.insetGrouped(
                header: const Text('允许朋友查看朋友圈的范围'),
                children: [
                  for (final item in const {
                    'ALL': '全部',
                    'SIX_MONTHS': '最近半年',
                    'ONE_MONTH': '最近一个月',
                    'THREE_DAYS': '最近三天'
                  }.entries)
                    CupertinoListTile(
                        title: Text(item.value),
                        trailing: _range == item.key
                            ? const Icon(CupertinoIcons.check_mark,
                                color: WeChatColors.brandPrimary)
                            : null,
                        onTap: _saving
                            ? null
                            : () {
                                setState(() => _range = item.key);
                                _save();
                              }),
                ]),
            CupertinoListSection.insetGrouped(
                footer: const Text(
                    '关闭后，其他人无法查看你的朋友圈，资料页也不再显示朋友圈入口。你仍可查看和管理自己的动态。'),
                children: [
                  CupertinoListTile(
                      key: const Key('moments-excluded-people'),
                      title: const Text('不给谁看'),
                      additionalInfo: Text(
                          _excluded.isEmpty ? '未设置' : '${_excluded.length}人'),
                      trailing: const CupertinoListTileChevron(),
                      onTap: _saving ? null : _choosePeople),
                  CupertinoListTile(
                      title: const Text('朋友圈入口'),
                      trailing: CupertinoSwitch(
                          key: const Key('moments-profile-entry-switch'),
                          value: _entry,
                          onChanged: _saving
                              ? null
                              : (v) {
                                  setState(() => _entry = v);
                                  _save();
                                })),
                ]),
            CupertinoListSection.insetGrouped(children: [
              CupertinoListTile(
                  title: const Text('个性化推荐'),
                  trailing: CupertinoSwitch(
                      value: _personalized,
                      onChanged: _saving
                          ? null
                          : (v) {
                              setState(() => _personalized = v);
                              _save();
                            }))
            ]),
          ],
        ])),
      );
}

class _ExcludedPeoplePage extends StatefulWidget {
  const _ExcludedPeoplePage({required this.api, required this.initial});
  final BusinessApiClient api;
  final List<String> initial;
  @override
  State<_ExcludedPeoplePage> createState() => _ExcludedPeopleState();
}

class _ExcludedPeopleState extends State<_ExcludedPeoplePage> {
  late final _selected = widget.initial.toSet();
  late Future<List<ContactSummary>> _contacts = widget.api.listContacts();
  String _query = '';
  @override
  Widget build(BuildContext context) => WeChatPageScaffold.navigation(
        navigationBar: CupertinoNavigationBar(
            middle: const Text('不给谁看'),
            trailing: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.pop(context, _selected.toList()),
                child: const Text('完成'))),
        child: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(12),
              child: CupertinoSearchTextField(
                  onChanged: (v) => setState(() => _query = v))),
          Expanded(
              child: FutureBuilder<List<ContactSummary>>(
                  future: _contacts,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                          child: CupertinoButton(
                              onPressed: () => setState(() {
                                    _contacts = widget.api.listContacts();
                                  }),
                              child: const Text('加载失败，重试')));
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CupertinoActivityIndicator());
                    }
                    final contacts = snapshot.data!
                        .where((c) => '${c.displayName} ${c.username}'
                            .toLowerCase()
                            .contains(_query.toLowerCase()))
                        .toList();
                    if (contacts.isEmpty) {
                      return const Center(child: Text('暂无好友'));
                    }
                    return ListView(children: [
                      for (final c in contacts)
                        CupertinoListTile(
                          key: ValueKey('exclude-${c.userId}'),
                          leading: UserAvatar(
                              nickname: c.displayName,
                              fallbackSeed: c.userId,
                              avatarUrl: c.avatarUrl,
                              size: 36),
                          title: Text(c.displayName),
                          trailing: Icon(
                              _selected.contains(c.userId)
                                  ? CupertinoIcons.check_mark_circled_solid
                                  : CupertinoIcons.circle,
                              color: _selected.contains(c.userId)
                                  ? WeChatColors.brandPrimary
                                  : CupertinoColors.systemGrey),
                          onTap: () => setState(() {
                            if (!_selected.remove(c.userId)) {
                              _selected.add(c.userId);
                            }
                          }),
                        )
                    ]);
                  })),
        ])),
      );
}
