import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'moments_page_store.dart';

/// 统一本地缓存仓库（优化 3）。
///
/// 各域缓存与存储后端的总览：
/// - **ProfileCache**：昵称/备注/头像 URL 等好友资料快照，由
///   `ProfileRepository` 的 `LegacySharedPreferencesStore` 持久化
///   （SharedPreferences，键 `identity.*`）——通讯录/会话页**先读缓存
///   立即渲染，再后台刷新**，本仓库提供 [profile] 门面与其对齐。
/// - **AvatarCache**：`flutter_cache_manager`（cached_network_image 共享）
///   按 URL 键的磁盘缓存；服务端签名 URL 自带版本语义——
///   `avatar:{userId}:{avatarVersion}` 的版本变化体现为 URL 变化，
///   旧条目由 cache manager 的 TTL/LRU 淘汰（30 天/500 对象）。
/// - **MomentsCache**：兼容首绘的首页 JSON + SQLite 条目/分页/cursor/
///   revision/tombstone；已浏览历史按页读取，媒体缓存键保持不变。
/// - **ConversationCache**：会话列表与 Timeline 的本地首绘由 **Matrix
///   SDK 的本地 SQLCipher 数据库**自管（`matrix_client_factory` 的
///   `databaseBuilder`）——房间列表/消息直接读本地库，天然"无需等待
///   网络"，因此不在此重复建表；本仓库仅保留文档职责。
///
/// 不缓存：消息正文解密缓存走 `MediaCache`/`MediaMemoryCache`（聊天域），
/// 资金/会话凭据走 SecureStorage——均不在 SharedPreferences 体系内。
final class CacheRepository {
  CacheRepository._(this._preferences, [MomentsPageStore? pageStore])
      : _pageStore = pageStore ?? _pageStoreForTest ?? MomentsPageStore();
  final MomentsPageStore _pageStore;
  static MomentsPageStore? _pageStoreForTest;

  // v2 rejects snapshots projected before the common-friend comment policy.
  // This namespace is metadata only; downloaded image bytes remain reusable.
  static const String momentsFeedKey = 'cache.moments.feed.latest.audience-v2';

  /// U04：朋友圈快照按账号命名空间——`<基键>.<accountKey>`。
  /// 账号切换/登出只清除对应账号的键，绝不让 B 首绘 A 的 feed，
  /// 也不全量删除其他账号数据或 Matrix 聊天历史。
  static String momentsFeedKeyFor(String accountKey) =>
      '$momentsFeedKey.$accountKey';

  static CacheRepository? _instance;
  static Future<CacheRepository>? _opening;
  static final _momentsGenerations = <String, int>{};
  static int momentsGeneration(String accountKey) =>
      _momentsGenerations[momentsFeedKeyFor(accountKey)] ?? 0;
  static Map<String, dynamic>? peekMoments(String? accountKey) =>
      accountKey == null ? null : _instance?.momentsFor(accountKey).snapshot;
  static String? peekMomentCover(String? accountKey) => accountKey == null
      ? null
      : _instance
          ?.momentsFor(accountKey)
          .preferencesSnapshot?['cover_url']
          ?.toString();
  static String? peekMomentCoverKey(String? accountKey) => accountKey == null
      ? null
      : _instance
          ?.momentsFor(accountKey)
          .preferencesSnapshot?['cover_cache_key']
          ?.toString();

  Future<void> saveMomentCover(String accountKey, String? url,
          {String? cacheKey, int? expectedGeneration}) =>
      momentsFor(accountKey)._saveCover(url, cacheKey, expectedGeneration);

  /// Available synchronously after the first initialization in this process.
  static CacheRepository? get current => _instance;

  /// 进程级单例；测试可用 [inject] 注入 mock preferences。
  static Future<CacheRepository> instance() => _instance != null
      ? Future.value(_instance)
      : _opening ??= SharedPreferences.getInstance().then((preferences) {
          return _instance ??= CacheRepository._(preferences);
        }).whenComplete(() => _opening = null);

  /// 测试专用：注入 mock preferences 并重置单例。
  static CacheRepository inject(SharedPreferences preferences,
          {MomentsPageStore? pageStore}) =>
      _instance = CacheRepository._(preferences, pageStore);

  static Future<void> resetForTest({MomentsPageStore? pageStore}) async {
    _instance = null;
    _opening = null;
    _momentsGenerations.clear();
    // Widget tests run in fake async; native SQLite needs an explicit fixture.
    _pageStoreForTest = pageStore ??
        MomentsPageStore(
            supportDirectory: () async =>
                throw UnsupportedError('No test SQLite fixture'));
  }

  final SharedPreferences _preferences;
  final _moments = <String, MomentsCache>{};

  /// U04：按账号取朋友圈缓存（accountKey = 业务账号稳定标识）。
  MomentsCache momentsFor(String accountKey) => _moments.putIfAbsent(
      accountKey,
      () => MomentsCache(
          _preferences, momentsFeedKeyFor(accountKey), _pageStore));

  ProfileCache get profile => const ProfileCache();
  AvatarCache get avatar => const AvatarCache();
}

/// 朋友圈首绘仍同步读取旧版首页快照；浏览过的分页单独写入 SQLite。
/// [saveHead] 用于首页刷新，[savePage] 用于分页，[mutateItem] 用于已确认
/// 修改。[save] 保留旧调用契约，并保守地失效历史页的权限投影。
///
/// U04：快照键含账号命名空间；损坏视为未命中。
final class MomentsCache {
  MomentsCache(this._preferences, this._storageKey,
      [MomentsPageStore? pageStore])
      : _pageStore = pageStore ?? MomentsPageStore();

  final MomentsPageStore _pageStore;
  final _pages = <String, Map<String, dynamic>>{};
  final _removedPosts = <String>{};
  final _removedComments = <String, Set<String>>{};

  /// Nonfatal: available memory/legacy head and authenticated network still work.
  Object? persistenceError;
  String get _invalidKey => '$_storageKey.pages-invalid';

  final SharedPreferences _preferences;
  final String _storageKey;
  Map<String, dynamic>? _snapshot;
  Map<String, dynamic>? _preferencesSnapshot;
  bool _loaded = false;
  bool _preferencesLoaded = false;
  int _feedRevision = 0;
  int _preferencesRevision = 0;
  Future<void> _writing = Future.value();

  /// Request tickets are shared across page instances for this account.
  int beginRefresh() => ++_feedRevision;
  int get currentRevision => _feedRevision;
  bool isCurrent(int ticket) => ticket == _feedRevision;
  int beginPreferencesRefresh() => ++_preferencesRevision;
  bool preferencesAreCurrent(int ticket) => ticket == _preferencesRevision;

  Map<String, dynamic>? get snapshot {
    if (!_loaded) {
      _snapshot = _decode(_storageKey);
      _loaded = true;
    }
    return _copy(_snapshot);
  }

  Map<String, dynamic>? get preferencesSnapshot {
    if (!_preferencesLoaded) {
      _preferencesSnapshot = _decode('$_storageKey.preferences');
      // Android 2072 stored cover fields separately; retain them on upgrade.
      if (_preferencesSnapshot == null &&
          _preferences.containsKey('$_storageKey.cover')) {
        _preferencesSnapshot = {
          'cover_url': _preferences.getString('$_storageKey.cover'),
          'cover_cache_key': _preferences.getString('$_storageKey.cover-key'),
        };
      }
      _preferencesLoaded = true;
    }
    return _copy(_preferencesSnapshot);
  }

  static Map<String, dynamic>? _copy(Map<String, dynamic>? value) =>
      value == null
          ? null
          : jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  Map<String, dynamic>? _decode(String key) {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null; // 快照损坏视为无缓存
    }
  }

  Map<String, dynamic>? loadSync() => snapshot;
  Future<Map<String, dynamic>?> load() async => snapshot;

  Future<void> restoreInvalidations() async {
    final generation = CacheRepository._momentsGenerations[_storageKey] ?? 0;
    try {
      await _writing;
      final rows = await _pageStore.readTombstones(_storageKey);
      if (!_generationIsCurrent(generation)) return;
      for (final row in rows) {
        final id = row['id'] as String;
        final comment = row['comment_id'] as String;
        if (comment.isEmpty) {
          _removedPosts.add(id);
        } else {
          (_removedComments[id] ??= {}).add(comment);
        }
      }
    } catch (error) {
      persistenceError = error;
    }
  }

  Future<Map<String, dynamic>?> loadPage(String cursor) async {
    final generation = CacheRepository._momentsGenerations[_storageKey] ?? 0;
    final ticket = _feedRevision;
    final memory = _pages[cursor];
    if (memory != null) return _copy(memory);
    if (_preferences.getBool(_invalidKey) == true) return null;
    try {
      await _writing;
      if (_preferences.getBool(_invalidKey) == true) return null;
      final page = await _pageStore.readPage(_storageKey, cursor);
      if (!_generationIsCurrent(generation) || !isCurrent(ticket)) return null;
      if (page != null) _pages[cursor] = page;
      return _copy(page);
    } catch (error) {
      persistenceError = error;
      return null;
    }
  }

  Map<String, dynamic> project(Map<String, dynamic> page) => {
        ...page,
        'items': [
          for (final raw in page['items'] as List? ?? const [])
            if (raw is! Map || !_removedPosts.contains(raw['id']?.toString()))
              if (raw is Map && raw['comments'] is List)
                {
                  ...raw,
                  'comments': [
                    for (final c in raw['comments'] as List)
                      if (c is! Map ||
                          !(_removedComments[raw['id']?.toString()]
                                  ?.contains(c['id']?.toString()) ??
                              false))
                        c
                  ]
                }
              else
                raw
        ]
      };

  /// Page writes retain the first-paint legacy head and serialize only this page.
  Future<void> savePage(String cursor, Map<String, dynamic> page,
      {required int ticket, required int expectedGeneration}) async {
    if (!isCurrent(ticket) || !_generationIsCurrent(expectedGeneration)) return;
    final value = project(_copy(page)!);
    if (value['next_cursor'] == cursor) value['next_cursor'] = null;
    _pages[cursor] = value;
    await _persist(() async {
      if (!isCurrent(ticket) || !_generationIsCurrent(expectedGeneration)) {
        return;
      }
      try {
        // A failed invalidation must be completed before accepting fresh pages.
        if (_preferences.getBool(_invalidKey) == true) {
          await _repairInvalidPages();
          await _preferences.remove(_invalidKey);
        }
        final persisted =
            await _pageStore.writePage(_storageKey, cursor, value);
        if (isCurrent(ticket) && _generationIsCurrent(expectedGeneration)) {
          _pages[cursor] = persisted;
        }
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
      }
    });
  }

  Future<void> saveHead(Map<String, dynamic> feed, {int? expectedGeneration}) =>
      _saveFeed(feed,
          expectedGeneration: expectedGeneration, invalidateOlder: false);

  Future<void> _repairInvalidPages() async {
    await _pageStore.invalidatePages(_storageKey);
    for (final id in _removedPosts) {
      await _pageStore.mutate(_storageKey, id, deleted: true);
    }
    for (final entry in _removedComments.entries) {
      for (final comment in entry.value) {
        await _pageStore.mutate(_storageKey, entry.key,
            deletedComment: comment);
      }
    }
  }

  Future<void> mutateItem(String id,
      {Map<String, dynamic>? fields,
      bool deleted = false,
      String? deletedComment}) async {
    ++_feedRevision;
    if (deleted) _removedPosts.add(id);
    if (deletedComment != null) {
      (_removedComments[id] ??= {}).add(deletedComment);
    }
    Map<String, dynamic> update(Map<String, dynamic> source) => project({
          ...source,
          'items': [
            for (final raw in source['items'] as List? ?? const [])
              if (raw is Map && raw['id']?.toString() == id)
                {...raw, ...?fields}
              else
                raw
          ]
        });
    final head = snapshot;
    if (head != null) _snapshot = update(head);
    _pages.updateAll((_, page) => update(page));
    final generation = CacheRepository._momentsGenerations[_storageKey] ?? 0;
    await _persist(() async {
      if (!_generationIsCurrent(generation)) return;
      // A crash/storage failure after a privacy mutation must fail closed on restart.
      final repair = _preferences.getBool(_invalidKey) == true;
      await _preferences.setBool(_invalidKey, true);
      if (_snapshot != null) {
        await _preferences.setString(_storageKey, jsonEncode(_snapshot));
      }
      try {
        if (repair) await _repairInvalidPages();
        await _pageStore.mutate(_storageKey, id,
            fields: fields, deleted: deleted, deletedComment: deletedComment);
        await _preferences.remove(_invalidKey);
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
      }
    });
  }

  Future<void> _persist(Future<void> Function() write) {
    final result = _writing.then((_) => write());
    _writing = result.catchError((Object error) {
      persistenceError = error;
    });
    return result;
  }

  bool _generationIsCurrent(int? expected) =>
      expected == null ||
      expected == (CacheRepository._momentsGenerations[_storageKey] ?? 0);

  Future<void> _saveCover(String? url, String? cacheKey, int? expected) async {
    if (!_generationIsCurrent(expected)) return;
    await savePreferences({
      ...?preferencesSnapshot,
      'cover_url': url,
      'cover_cache_key': url == null ? null : cacheKey,
    }, expectedGeneration: expected);
  }

  Future<void> save(Map<String, dynamic> feed, {int? expectedGeneration}) =>
      _saveFeed(feed,
          expectedGeneration: expectedGeneration, invalidateOlder: true);

  Future<void> _saveFeed(Map<String, dynamic> feed,
      {int? expectedGeneration, required bool invalidateOlder}) async {
    if (!_generationIsCurrent(expectedGeneration)) return;
    ++_feedRevision;
    final generation = CacheRepository._momentsGenerations[_storageKey] ?? 0;
    final deletedPosts = <String>[];
    final deletedComments = <(String, String)>[];
    if (invalidateOlder) {
      final incoming = <String, Map>{
        for (final raw in feed['items'] as List? ?? const [])
          if (raw is Map && raw['id'] != null) raw['id'].toString(): raw
      };
      for (final raw in snapshot?['items'] as List? ?? const []) {
        if (raw is! Map || raw['id'] == null) continue;
        final id = raw['id'].toString();
        final next = incoming[id];
        if (next == null) {
          deletedPosts.add(id);
          _removedPosts.add(id);
          continue;
        }
        final comments = {
          for (final c in next['comments'] as List? ?? const [])
            if (c is Map && c['id'] != null) c['id'].toString()
        };
        for (final c in raw['comments'] as List? ?? const []) {
          if (c is Map &&
              c['id'] != null &&
              !comments.contains(c['id'].toString())) {
            final comment = c['id'].toString();
            deletedComments.add((id, comment));
            (_removedComments[id] ??= {}).add(comment);
          }
        }
      }
    }
    _snapshot = project(_copy(feed)!);
    if (invalidateOlder) _pages.clear();
    _loaded = true;
    final value = _copy(_snapshot)!;
    final encoded = jsonEncode(value);
    await _persist(() async {
      if (!_generationIsCurrent(generation)) return;
      final repair = _preferences.getBool(_invalidKey) == true;
      if (invalidateOlder) await _preferences.setBool(_invalidKey, true);
      await _preferences.setString(_storageKey, encoded);
      try {
        if (repair) await _repairInvalidPages();
        for (final id in deletedPosts) {
          await _pageStore.mutate(_storageKey, id, deleted: true);
        }
        for (final deletion in deletedComments) {
          await _pageStore.mutate(_storageKey, deletion.$1,
              deletedComment: deletion.$2);
        }
        await _pageStore.writePage(_storageKey, null, value,
            invalidateOlder:
                invalidateOlder || _preferences.getBool(_invalidKey) == true);
        await _preferences.remove(_invalidKey);
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
      }
    });
  }

  Future<void> savePreferences(Map<String, dynamic> value,
      {int? expectedGeneration}) async {
    if (!_generationIsCurrent(expectedGeneration)) return;
    ++_preferencesRevision;
    _preferencesSnapshot = _copy(value);
    _preferencesLoaded = true;
    final encoded = jsonEncode(value);
    final cover = value['cover_url']?.toString();
    final coverKey =
        cover == null ? null : value['cover_cache_key']?.toString();
    await _persist(() async {
      if (!_generationIsCurrent(expectedGeneration)) return;
      await _preferences.setString('$_storageKey.preferences', encoded);
      if (cover == null) {
        await _preferences.remove('$_storageKey.cover');
      } else {
        await _preferences.setString('$_storageKey.cover', cover);
      }
      if (coverKey == null) {
        await _preferences.remove('$_storageKey.cover-key');
      } else {
        await _preferences.setString('$_storageKey.cover-key', coverKey);
      }
    });
  }

  Future<void> clear() async {
    CacheRepository._momentsGenerations[_storageKey] =
        (CacheRepository._momentsGenerations[_storageKey] ?? 0) + 1;
    ++_feedRevision;
    ++_preferencesRevision;
    _snapshot = null;
    _pages.clear();
    _removedPosts.clear();
    _removedComments.clear();
    _preferencesSnapshot = null;
    _loaded = _preferencesLoaded = true;
    await _persist(() async {
      await _preferences.setBool(_invalidKey, true);
      await _preferences.remove(_storageKey);
      await _preferences.remove('$_storageKey.preferences');
      await _preferences.remove('$_storageKey.cover');
      await _preferences.remove('$_storageKey.cover-key');
      try {
        await _pageStore.clear(_storageKey);
        await _preferences.remove(_invalidKey);
        persistenceError = null;
      } catch (error) {
        persistenceError = error;
      }
    });
  }
}

/// ProfileCache 门面：实际持久化在 ProfileRepository 的 identity.* 键。
/// 此处仅暴露缓存语义说明与键前缀，避免第二份事实来源。
final class ProfileCache {
  const ProfileCache();

  static const String keyPrefix = 'identity.';
}

/// AvatarCache 门面：磁盘缓存键语义说明。
final class AvatarCache {
  const AvatarCache();

  /// 服务端头像版本到缓存键的标准拼法（版本变化 ⇒ URL 变化 ⇒ 缓存失效）。
  String cacheKey(String userId, String avatarVersion) =>
      'avatar:$userId:$avatarVersion';
}
