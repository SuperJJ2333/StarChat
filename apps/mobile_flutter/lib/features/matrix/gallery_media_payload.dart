import 'dart:typed_data';

import 'device_gallery_source.dart';
import 'gif_image_policy.dart';
import 'video_transcode.dart';

/// Shared local preparation only. Each domain retains its own upload gateway.
const maxGalleryImageBytes = 20 * 1024 * 1024;

final class GalleryMediaPayload {
  const GalleryMediaPayload(this.bytes, this.mimeType, this.fileName);
  final Uint8List bytes;
  final String mimeType;
  final String fileName;
}

Future<GalleryMediaPayload> prepareGalleryMedia(GalleryPhoto photo,
    {required bool original, bool isGroup = false}) async {
  if (isGroup && photo.isVideo) {
    final size = await photo.originalSizeBytes?.call();
    if (size == null || size <= 0) throw StateError('无法读取视频大小，请重新选择');
    validateGroupVideoSize(size);
  }
  if (!photo.isVideo &&
      original &&
      (await photo.originalSizeBytes?.call() ?? 0) > maxGalleryImageBytes) {
    throw const FormatException('图片过大，请选择不超过 20MB 的图片');
  }
  final bytes =
      await (original ? photo.originalBytes() : photo.compressedBytes());
  if (bytes.isEmpty) throw const FormatException('图片为空，请重新选择');
  if (!photo.isVideo && bytes.length > maxGalleryImageBytes) {
    throw const FormatException('图片过大，请选择不超过 20MB 的图片');
  }
  validateGifStructureForSend(bytes);
  var mime = photo.mimeType;
  if (isGifBytes(bytes)) {
    mime = 'image/gif';
  } else if (bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255) {
    mime = 'image/jpeg';
  } else if (bytes.length >= 8 &&
      bytes[0] == 137 &&
      bytes[1] == 80 &&
      bytes[2] == 78 &&
      bytes[3] == 71) {
    mime = 'image/png';
  } else if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    mime = 'image/webp';
  }
  const extensions = {
    'image/gif': 'gif',
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/webp': 'webp'
  };
  return GalleryMediaPayload(bytes, mime, 'image.${extensions[mime] ?? 'bin'}');
}
