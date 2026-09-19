import 'dart:async';

import 'package:flutter/cupertino.dart';
import '../../core/business_api_client.dart';
import '../../core/cache/cache_repository.dart';
import '../../ui/components/wechat_scaffold.dart';
import '../../ui/components/user_avatar.dart';
import '../../ui/foundation/wechat_tokens.dart';
import '../contacts/contact_models.dart';
import '../matrix/profile_repository.dart';
import 'moments_privacy_changes.dart';
import '../../ui/motion/motion_page_route.dart';

class MomentsSettingsPage extends StatefulWidget {
  const MomentsSettingsPage({super.key, required this.api, this.identityCache});
  final BusinessApiClient api;

  /// 本地联系人投影：透传给「不给谁看」名单页做首帧渲染。
  final ProfileRepository? identityCache;
  @override
  State<MomentsSettingsPage> createState() => _MomentsSettingsState();
}

class _MomentsSettingsState extends State<MomentsSettingsPage> {
  String _range = 'ALL';
  bool _personalized = true, _entry = true, _loading = true, _saving = false;
  List<String> _excluded = [];

  /// 是否已经拿到过可展示的权威值（本地快照或服务端）。只有"从未有过值"
  /// 才允许整页错误——失败不覆盖已渲染的表单。
  bool _hasValues = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 本地优先：朋友圈首页已经把 `momentsPreferences()` 的完整负载写入本地
    // 快照（`CacheRepository` 的 `preferencesSnapshot`），这里先用它渲染表单，
    // 再后台刷新；断网时表单照样可用，而不是整页加载圈。
    try {
      final userId = await widget.api.currentMatrixUserId();
      final snapshot = userId == null || userId.isEmpty
          ? null
          : CacheRepository.current
              ?.momentsFor('matrix:$userId')
              .preferencesSnapshot;
      if (!mounted) return;
      if (snapshot != null && snapshot['history_range'] != null) {
        setState(() {
          _applyPreferences(snapshot);
          _loading = false;
          _hasValues = true;
        });
      }
    } catch (_) {
      // 本地快照不可用不阻塞网络刷新。
    }
    try {
      final r = await widget.api.momentsPreferences();
      if (!mounted) return;
      setState(() {
        _applyPreferences(r);
        _error = null;
        _loading = false;
        _hasValues = true;
      });
      // 回写快照：设置页自己的读取也要让本地缓存保持最新。
      unawaited(_persistPreferences(r));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // 失败不覆盖：已有权威值（缓存或此前成功）时保留表单，不弹整页错误。
        if (!_hasValues) _error = '权限加载失败，请重试';
      });
    }
  }

  void _applyPreferences(Map<String, dynamic> r) {
    _range = r['history_range'] as String? ?? 'ALL';
    _personalized = r['personalized_recommendations'] != false;
    _entry = r['profile_entry_enabled'] != false;
    _excluded = List<String>.from(r['excluded_user_ids'] ?? []);
  }

  Future<void> _persistPreferences(Map<String, dynamic> value) async {
    try {
      final userId = await widget.api.currentMatrixUserId();
      if (userId == null || userId.isEmpty) return;
      final cache = CacheRepository.current?.momentsFor('matrix:$userId');
      await cache?.savePreferences({...?cache.preferencesSnapshot, ...value});
    } catch (_) {
      // 本地快照写失败不是刷新失败。
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
      unawaited(_persistPreferences({
        'history_range': _range,
        'personalized_recommendations': _personalized,
        'profile_entry_enabled': _entry,
        'excluded_user_ids': _excluded,
      }));
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _choosePeople() async {
    final selected = await Navigator.push<List<String>>(
        context,
        MotionPageRoute(
            builder: (_) => _ExcludedPeoplePage(
                api: widget.api,
                initial: _excluded,
                identityCache: widget.identityCache)));
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
  const _ExcludedPeoplePage(
      {required this.api, required this.initial, this.identityCache});
  final BusinessApiClient api;
  final List<String> initial;
  final ProfileRepository? identityCache;
  @override
  State<_ExcludedPeoplePage> createState() => _ExcludedPeopleState();
}

class _ExcludedPeopleState extends State<_ExcludedPeoplePage> {
  late final _selected = widget.initial.toSet();

  /// 本地优先：先用已水合的联系人投影渲染，再后台刷新；失败保留已有列表。
  List<ContactSummary> _contacts = const [];
  bool _loading = false;
  Object? _error;
  int _generation = 0;
  bool _disposed = false;
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
      final contacts = await widget.api.listContacts();
      if (_disposed || generation != _generation) return;
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
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
              child: Builder(builder: (context) {
            final contacts = _contacts
                .where((c) => '${c.displayName} ${c.username}'
                    .toLowerCase()
                    .contains(_query.toLowerCase()))
                .toList();
            if (contacts.isEmpty) {
              // 本地优先 / 失败不覆盖：只有"没有任何本地联系人且确实失败"
              // 才显示错误；有内容时即使刷新失败也继续可选。
              if (_loading) {
                return const Center(child: CupertinoActivityIndicator());
              }
              if (_error != null && _contacts.isEmpty) {
                return Center(
                    child: CupertinoButton(
                        key: const Key('moments-excluded-retry'),
                        onPressed: () => unawaited(_load()),
                        child: const Text('加载失败，重试')));
              }
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
