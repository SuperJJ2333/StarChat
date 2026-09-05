import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// The sole remote-avatar cache. Keys vary by user, avatar version/URL and size.
abstract final class AvatarCache {
  static const diskTtl = Duration(days: 30);
  static const maximumMemoryEntries = 200;
  static const maximumDiskEntries = 500;

  static final CacheManager manager = CacheManager(
    Config(
      'changliao-member-avatars-v1',
      stalePeriod: diskTtl,
      maxNrOfCacheObjects: maximumDiskEntries,
    ),
  );

  static final Map<String, Set<String>> _keysByUser = {};
  static final Map<String, ImageProvider> _lastSuccessfulByUser = {};

  static void configureMemoryCache() {
    final cache = PaintingBinding.instance.imageCache;
    if (cache.maximumSize < maximumMemoryEntries) {
      cache.maximumSize = maximumMemoryEntries;
    }
  }

  /// 头像版本：URL 的 `?v=`/`?version=` 参数，否则用规范化 URL 哈希。
  /// 好友换头像 → URL/版本变化 → 缓存键变化，旧条目逐出。
  static String avatarVersion(String avatarUrl) {
    final uri = Uri.tryParse(avatarUrl);
    final queryVersion =
        uri?.queryParameters['v'] ?? uri?.queryParameters['version'];
    return queryVersion == null
        ? sanitizedUrl(avatarUrl).hashCode.toRadixString(16)
        : 'v=$queryVersion';
  }

  /// 统一缓存键：avatar:{userId}:{avatarVersion}（BUG 1 规范）。
  static String friendAvatarCacheKey(String userId, String version) =>
      'avatar:$userId:$version';

  static String cacheKey({
    required String userId,
    required String avatarUrl,
    double? size,
  }) {
    // 渲染尺寸不参与键：所有页面共享同一条头像缓存，避免重复下载。
    return friendAvatarCacheKey(userId, avatarVersion(avatarUrl));
  }

  static String sanitizedUrl(String avatarUrl) {
    final uri = Uri.tryParse(avatarUrl);
    if (uri == null || !uri.hasScheme) return '<invalid-url>';
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  static AvatarCacheImageProvider imageProvider({
    required String userId,
    required String avatarUrl,
    required double size,
    Map<String, String>? headers,
  }) {
    configureMemoryCache();
    final key = cacheKey(userId: userId, avatarUrl: avatarUrl, size: size);
    (_keysByUser[userId] ??= <String>{}).add(key);
    return buildProvider(
      avatarUrl: avatarUrl,
      cacheKey: key,
      cacheManager: manager,
      headers: headers,
    );
  }

  /// Retains the last painted custom avatar while a replacement image decodes.
  static void rememberSuccessful(String userId, ImageProvider provider) {
    _lastSuccessfulByUser[userId] = provider;
  }

  static ImageProvider? lastSuccessful(String userId) =>
      _lastSuccessfulByUser[userId];

  @visibleForTesting
  static AvatarCacheImageProvider buildProvider({
    required String avatarUrl,
    required String cacheKey,
    BaseCacheManager? cacheManager,
    Map<String, String>? headers,
  }) {
    return AvatarCacheImageProvider(
      avatarUrl,
      cacheKey: cacheKey,
      cacheManager: cacheManager,
      headers: headers,
    );
  }

  static Future<void> invalidateUser(String userId) async {
    _lastSuccessfulByUser.remove(userId);
    final keys = _keysByUser.remove(userId) ?? const <String>{};
    for (final key in keys) {
      await manager.removeFile(key);
    }
  }
}

@immutable
final class AvatarCacheImageProvider extends CachedNetworkImageProvider {
  const AvatarCacheImageProvider(
    super.url, {
    super.cacheKey,
    super.cacheManager,
    super.maxWidth,
    super.maxHeight,
    super.headers,
  });
}
