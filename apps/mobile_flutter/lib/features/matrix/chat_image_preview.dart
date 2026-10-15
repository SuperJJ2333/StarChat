import 'dart:typed_data';

import 'gif_image_policy.dart';
import 'emoji_preview_cache.dart';

/// Bubbles prefer the encrypted thumbnail, including GIFs. Animated sources
/// become a small static first frame; viewers still load the original stream.
Future<Uint8List> loadChatImagePreview({
  required bool animated,
  required Future<Uint8List?> Function() loadThumbnail,
  required Future<Uint8List> Function() loadOriginal,
}) async {
  Uint8List? thumbnail;
  try {
    thumbnail = await loadThumbnail();
  } catch (_) {
    // Legacy optional thumbnails may fail; trusted callers enforce their
    // declared thumbnail contract before entering this fallback helper.
  }
  if (thumbnail != null && thumbnail.isNotEmpty) {
    return animated ? createEmojiPreview(thumbnail) : thumbnail;
  }
  final bytes = await loadOriginal();
  validateGifForSend(bytes);
  return animated ? createEmojiPreview(bytes) : bytes;
}
