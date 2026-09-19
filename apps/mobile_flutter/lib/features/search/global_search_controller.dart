import 'dart:async';

import 'package:flutter/foundation.dart';

import 'global_search_index.dart';
import 'global_search_models.dart';
import 'local_message_search_repository.dart';

/// 全局搜索查询生命周期（Task B）：
/// 200~300ms 防抖、query generation、取消、stale 结果抑制、章节限量
/// （首页每节最多 [sectionLimit] 条 + 「更多…」入口）。
///
/// 安全边界：联系人来自本机身份缓存投影，房间来自本机会话快照，
/// 聊天记录来自 [GlobalSearchIndex]（本机已解密内容；有 [repository] 时
/// 走该账号维度的本机历史索引）。控制器**不发起任何请求**，
/// 因此查询词与明文都不出设备。
final class GlobalSearchController extends ChangeNotifier {
  GlobalSearchController({
    required this.loadContacts,
    required this.loadRooms,
    required this.index,
    this.repository,
    this.debounce = const Duration(milliseconds: 250),
    this.sectionLimit = 3,
    this.hitLimit = 200,
  }) {
    repository?.addListener(_onLocalHistoryChanged);
  }

  final Future<List<GlobalSearchContactResult>> Function() loadContacts;
  final Future<List<GlobalSearchRoomResult>> Function() loadRooms;
  final GlobalSearchIndex index;

  /// 账号维度的本机历史仓库；提供时聊天记录检索走它（账号隔离 + 本机库回填）。
  final LocalMessageSearchRepository? repository;
  final Duration debounce;
  final int sectionLimit;
  final int hitLimit;

  String _query = '';
  String get query => _query;
  bool loading = false;
  Object? error;
  GlobalSearchResults results = GlobalSearchResults.empty;
  int _epoch = 0;
  Timer? _timer;
  bool _disposed = false;

  /// 本机历史索引被回填/增量更新时，用当前查询重新出结果。
  void _onLocalHistoryChanged() {
    if (_disposed || isBlank) return;
    unawaited(refresh());
  }

  /// 聊天记录是否来自账号维度的本机历史仓库（否则是本会话共享索引）。
  bool get searchesLocalHistoryRepository => repository != null;

  /// 空查询：页面保持干净（不显示任何结果）。
  bool get isBlank => _query.trim().isEmpty;
  bool get hasResults => results.isNotEmpty;
  bool get hasMoreContacts => results.contacts.length > sectionLimit;
  bool get hasMoreRooms => results.rooms.length > sectionLimit;
  bool get hasMoreConversations => results.conversations.length > sectionLimit;

  List<GlobalSearchContactResult> get visibleContacts =>
      _limited(results.contacts, sectionLimit);
  List<GlobalSearchRoomResult> get visibleRooms =>
      _limited(results.rooms, sectionLimit);
  List<GlobalSearchConversationHit> get visibleConversations =>
      _limited(results.conversations, sectionLimit);

  static List<T> _limited<T>(List<T> all, int limit) =>
      all.length > limit ? all.sublist(0, limit) : all;

  /// 关键词变化：防抖调度；立即清空结果（空查询立即生效）。
  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _epoch++;
    _timer?.cancel();
    _timer = null;
    if (isBlank) {
      loading = false;
      error = null;
      results = GlobalSearchResults.empty;
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    _timer = Timer(debounce, () => unawaited(refresh()));
  }

  /// 立即执行（测试与「提交搜索」用）；迟到的旧代次结果会被丢弃。
  Future<void> refresh() async {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    if (isBlank) {
      results = GlobalSearchResults.empty;
      loading = false;
      error = null;
      notifyListeners();
      return;
    }
    final epoch = ++_epoch;
    loading = true;
    error = null;
    notifyListeners();
    try {
      // 本地优先 / 立即展示：房间来自本机会话快照、聊天记录来自本机索引，先把它们
      // 发布出来；联系人加载器在接线缺缓存时可能要走网络，绝不能把已经完全本地的
      // 结果卡在它后面（微信级加载模型 L2）。
      final rooms = await loadRooms();
      if (epoch != _epoch || _disposed) return; // stale：旧查询不得覆盖新结果
      var contacts = results.contacts;
      void publish() {
        final needle = _query.trim().toLowerCase();
        final activeRepository = repository;
        final hits = activeRepository == null
            ? index.search(needle, limit: hitLimit)
            : activeRepository.search(needle, limit: hitLimit);
        results = GlobalSearchResults(
          contacts: [
            for (final contact in contacts)
              if (_matchesContact(contact, needle)) contact,
          ],
          rooms: [
            for (final room in rooms)
              if (!room.isDirect && _matchesRoom(room, needle)) room,
          ],
          conversations: aggregateConversationHits(hits),
        );
      }

      // 先发布：本地房间/聊天记录立刻可见。
      publish();
      loading = false;
      notifyListeners();

      // 联系人到位后再补一次（此时才可能出现网络等待）。
      final fresh = await loadContacts();
      if (epoch != _epoch || _disposed) return;
      contacts = fresh;
      publish();
      notifyListeners();
    } catch (error) {
      if (epoch != _epoch || _disposed) return;
      this.error = error;
      loading = false;
      notifyListeners();
    }
  }

  static bool _matchesContact(
          GlobalSearchContactResult contact, String needle) =>
      contact.displayName.toLowerCase().contains(needle) ||
      contact.username.toLowerCase().contains(needle) ||
      (contact.nickname?.toLowerCase().contains(needle) ?? false);

  static bool _matchesRoom(GlobalSearchRoomResult room, String needle) =>
      room.displayName.toLowerCase().contains(needle);

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    repository?.removeListener(_onLocalHistoryChanged);
    super.dispose();
  }
}
