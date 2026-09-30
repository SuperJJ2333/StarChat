import 'dart:io';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../features/media/media_asset_gateway.dart';
import 'gallery_save_access.dart';

/// Gallery writes share permission handling and truthful original metadata.
/// The caller's loader/guard retain account, source and cancellation authority.
abstract final class GalleryMediaExport {
  static Future<AssetEntity> saveImage({
    required Future<Uint8List> Function() loadOriginal,
    required String filename,
    void Function()? ensureCurrent,
  }) async {
    ensureCurrent?.call();
    await ensureGallerySaveAccess();
    ensureCurrent?.call();
    final bytes = await MediaAssetGateway.readOriginal(loadOriginal);
    ensureCurrent?.call();
    final result = await PhotoManager.editor.saveImage(bytes,
        filename: MediaAssetGateway.exportFilename(bytes, filename: filename));
    ensureCurrent?.call();
    return result;
  }

  static Future<AssetEntity> saveVideo({
    required File original,
    required String title,
    void Function()? ensureCurrent,
  }) async {
    ensureCurrent?.call();
    await ensureGallerySaveAccess();
    ensureCurrent?.call();
    final result = await PhotoManager.editor.saveVideo(original, title: title);
    ensureCurrent?.call();
    return result;
  }
}
