import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../foundation/retained_image_cache_manager.dart';

final _momentImageCache = RetainedImageCacheManager(
    Config('changliao-moment-images-v1', maxNrOfCacheObjects: 500));

class _MomentImageProvider extends CachedNetworkImageProvider {
  const _MomentImageProvider(super.url, {super.cacheKey});

  // Constructing/comparing an image identity must not initialize disk storage.
  @override
  BaseCacheManager get cacheManager => _momentImageCache;
}

/// A signed URL can change while its immutable business media object does not.
/// Only server-projected stable keys are reused; unknown URLs keep normal URL
/// identity, avoiding accidental reuse when an image is replaced.
CachedNetworkImageProvider momentImageProvider(String url,
        [String? stableKey, String namespace = '']) =>
    _MomentImageProvider(url,
        cacheKey: stableKey == null || stableKey.isEmpty || namespace.isEmpty
            ? null
            : '${Uri.tryParse(url)?.origin}:moment:$namespace:$stableKey');

String? momentImageKey(List<String> keys, int index) =>
    index < keys.length ? keys[index] : null;
