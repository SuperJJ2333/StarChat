import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_image_compress/flutter_image_compress.dart';

/// 单张图片压缩后的硬性上限。
const maxMomentImageEdge = 1080;
const maxMomentImageBytes = 500 * 1024;

/// 朋友圈图片预处理异常：调用方据此给出明确提示，绝不静默失败或崩溃。
final class MomentImageException implements Exception {
  const MomentImageException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 计算等比缩放目标：最长边不超过 [maxEdge]，短边按比例取整（至少 1px）。
({int width, int height}) targetDimensions(
  int width,
  int height,
  int maxEdge,
) {
  if (width <= 0 || height <= 0) return (width: 1, height: 1);
  final longest = width > height ? width : height;
  if (longest <= maxEdge) return (width: width, height: height);
  final scale = maxEdge / longest;
  return (
    width: (width * scale).floor().clamp(1, maxEdge),
    height: (height * scale).floor().clamp(1, maxEdge),
  );
}

/// 朋友圈图片发布前的统一压缩管线：
/// - 最长边 ≤1080px（等比缩放，解码由系统完成，自动应用 EXIF 方向）；
/// - 统一转 JPEG，质量自 85 逐级降至 55，直到 ≤500KB；
/// - 保留 EXIF（含方向信息），避免照片旋转错乱；
/// - 压缩管线失败时抛出 [MomentImageException]，不吞错、不崩溃。
final class MomentImagePreprocessor {
  /// 直接注入整条处理管线（测试用，绕过真实解码器）。
  MomentImagePreprocessor.functional(this._processFn)
      : _compressBytes = null;

  MomentImagePreprocessor({
    Future<Uint8List?> Function(
      Uint8List bytes, {
      required int minWidth,
      required int minHeight,
      required int quality,
    })?
    compressBytes,
  })  : _compressBytes = compressBytes ?? FlutterImageCompress.compressWithList,
        _processFn = null;

  final Future<Uint8List?> Function(
    Uint8List bytes, {
    required int minWidth,
    required int minHeight,
    required int quality,
  })? _compressBytes;
  final Future<Uint8List> Function(Uint8List bytes)? _processFn;

  static const qualityLadder = [85, 70, 55];

  Future<Uint8List> process(Uint8List bytes) {
    final override = _processFn;
    if (override != null) return override(bytes);
    return _process(bytes);
  }

  Future<Uint8List> _process(Uint8List bytes) async {
    final ({int width, int height}) target;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      target = targetDimensions(image.width, image.height, maxMomentImageEdge);
      image.dispose();
      codec.dispose();
    } catch (_) {
      throw const MomentImageException('图片格式不受支持或文件已损坏，请更换图片后重试');
    }

    final compress = _compressBytes;
    if (compress == null) {
      throw StateError('compressor unavailable');
    }
    Uint8List? output;
    for (final quality in qualityLadder) {
      try {
        output = await compress(
          bytes,
          minWidth: target.width,
          minHeight: target.height,
          quality: quality,
        );
      } on MomentImageException {
        rethrow;
      } catch (_) {
        throw const MomentImageException(
          '图片处理失败，可能是格式不受支持，请更换图片后重试',
        );
      }
      if (output != null && output.lengthInBytes <= maxMomentImageBytes) {
        return output;
      }
    }
    if (output == null) {
      throw const MomentImageException('图片处理失败，请更换图片后重试');
    }
    // 最低质量仍超限：返回最优结果并交由上层继续上传（极少数超大图），
    // 不因字节略超上限而阻断发布。
    return output;
  }
}
