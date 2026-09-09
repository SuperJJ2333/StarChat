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

  static CachedNetworkImageProvider imageProvider(String url) =>
      CachedNetworkImageProvider(url, cacheManager: manager);
}
