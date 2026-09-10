import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../foundation/retained_image_cache_manager.dart';

/// Shared by feed thumbnails and the full-screen viewer. Flutter retains decoded
/// frames in its bounded image cache; originals are also reusable from disk.
class _MomentImageProvider extends CachedNetworkImageProvider {
  const _MomentImageProvider(super.url, {super.cacheKey});

  // Comparing identities must not initialize platform disk storage.
  @override
  BaseCacheManager get cacheManager => MomentMediaCache.manager;
}

abstract final class MomentMediaCache {
  /// Called only after a failed decode/load. Remove a damaged disk entry as
  /// well as the failed decoded frame so the explicit retry can recover.
  static Future<void> retry(CachedNetworkImageProvider provider) async {
    await manager.removeFile(provider.cacheKey ?? provider.url);
    await provider.evict();
  }

  static Object imageIdentity(String url,
          {String? cacheKey, String? accountKey, String? trustedOrigin}) =>
      (
        accountKey,
        trustedOrigin,
        imageProvider(url,
                    cacheKey: cacheKey,
                    accountKey: accountKey,
                    trustedOrigin: trustedOrigin)
                .cacheKey ??
            url,
      );
  static const diskTtl = Duration(days: 7);
  static const maximumDiskEntries = 200;
  static const maximumConcurrentDownloads = 3;
  static final CacheManager manager = RetainedImageCacheManager(Config(
    'changliao-moments-media-v1',
    stalePeriod: diskTtl,
    maxNrOfCacheObjects: maximumDiskEntries,
    fileService: HttpFileService()
      ..concurrentFetches = maximumConcurrentDownloads,
  ));

  static CachedNetworkImageProvider imageProvider(
    String url, {
    String? cacheKey,
    String? accountKey,
    String? trustedOrigin,
  }) {
    final uri = Uri.tryParse(url);
    final validKey =
        cacheKey != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(cacheKey);
    final trusted = uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.origin == trustedOrigin &&
        RegExp(r'^/api/v1/profile/avatar/content/[^/]+$').hasMatch(uri.path);
    // Read-only server digests are not authorization. Require the verified
    // account and exact API origin, never decode tokens or strip URL parts.
    final scoped = validKey &&
            trusted &&
            accountKey != null &&
            accountKey.isNotEmpty
        ? 'moments-origin-account-v1:${sha256.convert(utf8.encode(jsonEncode([
                uri.origin,
                accountKey,
                cacheKey
              ])))}'
        : accountKey != null && accountKey.isNotEmpty
            ? 'moments-url-account-v1:${sha256.convert(utf8.encode(jsonEncode([
                    accountKey,
                    url,
                  ])))}'
            : null;
    return _MomentImageProvider(url, cacheKey: scoped);
  }
}
