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

  static String cacheKey({
    required String userId,
    required String avatarUrl,
    required double size,
  }) {
    final uri = Uri.tryParse(avatarUrl);
    final queryVersion =
        uri?.queryParameters['v'] ?? uri?.queryParameters['version'];
    final version = queryVersion == null
        ? avatarUrl.hashCode.toRadixString(16)
        : 'v=$queryVersion';
    return 'avatar-$userId-$version-${size.round()}';
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
