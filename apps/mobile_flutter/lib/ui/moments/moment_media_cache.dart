import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared by feed thumbnails and the full-screen viewer. Flutter retains decoded
/// frames in its bounded image cache; originals are also reusable from disk.
abstract final class MomentMediaCache {
  static const diskTtl = Duration(days: 7);
  static const maximumDiskEntries = 200;
  static final CacheManager manager = CacheManager(Config(
    'changliao-moments-media-v1',
    stalePeriod: diskTtl,
    maxNrOfCacheObjects: maximumDiskEntries,
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
        : null;
    return CachedNetworkImageProvider(url,
        cacheManager: manager, cacheKey: scoped);
  }
}
