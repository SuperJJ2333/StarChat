import 'dart:typed_data';

import 'gif_image_policy.dart';

/// Static images use the encrypted thumbnail; animated images retain their
/// original stream. Legacy messages without a thumbnail load only on demand.
Future<Uint8List> loadChatImagePreview({
  required bool animated,
  required Future<Uint8List?> Function() loadThumbnail,
  required Future<Uint8List> Function() loadOriginal,
}) async {
  if (!animated) {
    try {
      final thumbnail = await loadThumbnail();
      if (thumbnail != null && thumbnail.isNotEmpty) return thumbnail;
    } catch (_) {
      // A missing/corrupt thumbnail must not make the attachment inaccessible.
    }
  }
  final bytes = await loadOriginal();
  validateGifForSend(bytes);
  return bytes;
}
