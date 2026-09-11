import 'package:flutter/foundation.dart';

import 'moment_media_cache.dart';

abstract final class MomentViewerSource {
  static Object identityAt({
    required List<String> urls,
    required List<String?> cacheKeys,
    required int index,
    required String accountKey,
    required String? trustedOrigin,
  }) =>
      MomentMediaCache.imageIdentity(urls[index],
          accountKey: accountKey,
          trustedOrigin: trustedOrigin,
          cacheKey: index < cacheKeys.length ? cacheKeys[index] : null);

  static int matchingIndex({
    required List<String> oldUrls,
    required List<String?> oldCacheKeys,
    required List<String> newUrls,
    required List<String?> newCacheKeys,
    required int currentIndex,
    required String oldAccountKey,
    required String newAccountKey,
    required String? oldOrigin,
    required String? newOrigin,
  }) {
    if (oldAccountKey != newAccountKey ||
        oldOrigin != newOrigin ||
        oldUrls.isEmpty) {
      return -1;
    }
    final oldIndex = currentIndex.clamp(0, oldUrls.length - 1);
    final current = identityAt(
        urls: oldUrls,
        cacheKeys: oldCacheKeys,
        index: oldIndex,
        accountKey: oldAccountKey,
        trustedOrigin: oldOrigin);
    for (var index = 0; index < newUrls.length; index++) {
      if (identityAt(
              urls: newUrls,
              cacheKeys: newCacheKeys,
              index: index,
              accountKey: newAccountKey,
              trustedOrigin: newOrigin) ==
          current) {
        return index;
      }
    }
    return -1;
  }

  static bool same({
    required List<String> oldUrls,
    required List<String?> oldCacheKeys,
    required List<String> newUrls,
    required List<String?> newCacheKeys,
    required String oldAccountKey,
    required String newAccountKey,
    required String? oldOrigin,
    required String? newOrigin,
  }) =>
      oldAccountKey == newAccountKey &&
      oldOrigin == newOrigin &&
      listEquals(
          List.generate(
              oldUrls.length,
              (index) => identityAt(
                  urls: oldUrls,
                  cacheKeys: oldCacheKeys,
                  index: index,
                  accountKey: oldAccountKey,
                  trustedOrigin: oldOrigin)),
          List.generate(
              newUrls.length,
              (index) => identityAt(
                  urls: newUrls,
                  cacheKeys: newCacheKeys,
                  index: index,
                  accountKey: newAccountKey,
                  trustedOrigin: newOrigin)));
}
