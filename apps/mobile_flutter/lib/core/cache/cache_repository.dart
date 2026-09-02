import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 统一本地缓存仓库（优化 3）。
///
/// 各域缓存与存储后端的总览：
/// - **ProfileCache**：昵称/备注/头像 URL 等好友资料快照，由
///   `ChatIdentityCache` 的 `SharedPreferencesChatIdentityStore` 持久化
///   （SharedPreferences，键 `identity.*`）——通讯录/会话页**先读缓存
///   立即渲染，再后台刷新**，本仓库提供 [profile] 门面与其对齐。
/// - **AvatarCache**：`flutter_cache_manager`（cached_network_image 共享）
///   按 URL 键的磁盘缓存；服务端签名 URL 自带版本语义——
///   `avatar:{userId}:{avatarVersion}` 的版本变化体现为 URL 变化，
///   旧条目由 cache manager 的 TTL/LRU 淘汰（30 天/500 对象）。
/// - **MomentsCache**：最近一页 Feed 的 JSON 快照（本仓库实现，
///   朋友圈页先绘缓存 → 后台刷新），杜绝每次进入全量重新下载照片。
/// - **ConversationCache**：会话列表与 Timeline 的本地首绘由 **Matrix
///   SDK 的本地 SQLCipher 数据库**自管（`matrix_client_factory` 的
///   `databaseBuilder`）——房间列表/消息直接读本地库，天然"无需等待
///   网络"，因此不在此重复建表；本仓库仅保留文档职责。
///
/// 不缓存：消息正文解密缓存走 `MediaCache`/`MediaMemoryCache`（聊天域），
/// 资金/会话凭据走 SecureStorage——均不在 SharedPreferences 体系内。
final class CacheRepository {
  CacheRepository._(this._preferences);

  static const String momentsFeedKey = 'cache.moments.feed.latest';

  static CacheRepository? _instance;

  /// 进程级单例；测试可用 [inject] 注入 mock preferences。
  static Future<CacheRepository> instance() async =>
      _instance ??= CacheRepository._(await SharedPreferences.getInstance());

  /// 测试专用：注入 mock preferences 并重置单例。
  static CacheRepository inject(SharedPreferences preferences) =>
      _instance = CacheRepository._(preferences);

  static Future<void> resetForTest() async {
    _instance = null;
  }

  final SharedPreferences _preferences;

  MomentsCache get moments => MomentsCache(_preferences);
  ProfileCache get profile => const ProfileCache();
  AvatarCache get avatar => const AvatarCache();
}

/// 朋友圈 Feed 快照：最近一次 `GET /moments/feed?mode=latest` 的原始
/// 响应 JSON。朋友圈页用它完成**首绘**（存在缓存时首屏无需等待网络），
/// 随后后台刷新并覆盖写入。
final class MomentsCache {
  MomentsCache(this._preferences);

  final SharedPreferences _preferences;

  Future<Map<String, dynamic>?> load() async {
    final raw = _preferences.getString(CacheRepository.momentsFeedKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null; // 快照损坏视为无缓存
    }
  }

  Future<void> save(Map<String, dynamic> feed) async {
    await _preferences.setString(
        CacheRepository.momentsFeedKey, jsonEncode(feed));
  }

  Future<void> clear() =>
      _preferences.remove(CacheRepository.momentsFeedKey);
}

/// ProfileCache 门面：实际持久化在 ChatIdentityCache 的 identity.* 键。
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
