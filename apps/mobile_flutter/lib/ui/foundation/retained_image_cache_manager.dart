import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../../features/media/media_asset_gateway.dart';

class RetainedImageCacheManager extends CacheManager {
  RetainedImageCacheManager(super.config);

  /// A signed URL expiring does not invalidate previously downloaded pixels.
  /// Explicit removal still uses removeFile; refresh failures preserve the last
  /// successful file until normal quota/age eviction or an explicit removal.
  @override
  Stream<FileResponse> getFileStream(String url,
      {String? key,
      Map<String, String>? headers,
      bool withProgress = false}) async* {
    final effectiveKey = key ?? url;
    FileInfo? cached;
    try {
      cached = await getFileFromCache(effectiveKey);
      if (cached != null) await _checked(cached);
    } on Exception {
      // A damaged cache index must not prevent a normal network load.
      if (cached != null) {
        try {
          await removeFile(effectiveKey);
        } on Exception {
          // The subsequent cold read still verifies any surviving alias.
        }
      }
      cached = null;
    }
    if (cached == null) {
      await for (final response in super.getFileStream(url,
          key: effectiveKey, headers: headers, withProgress: withProgress)) {
        yield response is FileInfo ? await _checked(response) : response;
      }
      return;
    }
    yield cached;
    if (!cached.validTill.isBefore(DateTime.now())) return;
    try {
      yield await _checked(
          await downloadFile(url, key: effectiveKey, authHeaders: headers));
    } on Exception {
      // Do not forward an error after a usable image, or the image provider
      // would evict the successful decoded frame and replace it with fallback.
    }
  }

  Future<FileInfo> _checked(FileInfo entry) async {
    await MediaAssetGateway.readFile(() async => entry.file);
    return entry;
  }
}
