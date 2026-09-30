import 'dart:typed_data';

import 'device_gallery_source.dart';
import '../media/media_asset_gateway.dart';
import '../media/image_compression_policy.dart';
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
  if (photo.isVideo) {
    final bytes = await photo.compressedBytes();
    if (bytes.isEmpty) throw const VideoCompressionException();
    validateGroupVideoSize(bytes.length);
    return GalleryMediaPayload(bytes, 'video/mp4', 'video.mp4');
  }
  if ((await photo.originalSizeBytes?.call() ?? 0) > maxGalleryImageBytes) {
    throw const FormatException('图片过大，请选择不超过 20MB 的图片');
  }
  // The unified policy is the sole encoder. Native gallery thumbnails must
  // not replace a saved compliant original before identity is established.
  final bytes = await photo.originalBytes();
  if (bytes.isEmpty) throw const FormatException('图片为空，请重新选择');
  if (!photo.isVideo && bytes.length > maxGalleryImageBytes) {
    throw const FormatException('图片过大，请选择不超过 20MB 的图片');
  }
  final processed = await ImageCompressionPolicy.prepare(bytes);
  final asset = await MediaAssetGateway.inspect(processed,
      mimeType: photo.mimeType, filename: 'image');
  return GalleryMediaPayload(asset.bytes, asset.mimeType, asset.filename);
}
