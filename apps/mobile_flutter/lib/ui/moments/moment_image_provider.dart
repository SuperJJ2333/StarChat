import 'package:cached_network_image/cached_network_image.dart';
import 'moment_media_cache.dart';

/// Compatibility entry point: stable private identity requires an explicitly
/// trusted origin, as well as an account and a server-issued digest.
CachedNetworkImageProvider momentImageProvider(String url,
        [String? stableKey, String namespace = '', String? trustedOrigin]) =>
    MomentMediaCache.imageProvider(url,
        cacheKey: stableKey,
        accountKey: namespace,
        trustedOrigin: trustedOrigin);

String? momentImageKey(List<String?> keys, int index) =>
    index < keys.length ? keys[index] : null;
