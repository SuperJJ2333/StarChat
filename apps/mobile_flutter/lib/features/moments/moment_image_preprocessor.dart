import 'dart:typed_data';
import 'dart:ui' as ui;

import '../media/media_asset_gateway.dart';
import '../media/image_compression_policy.dart';

/// 单张图片压缩后的硬性上限。
const maxMomentImageEdge = maxUnifiedImageEdge;
const maxMomentImageBytes = maxUnifiedImageBytes;

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

/// 朋友圈沿用共享图片预算与动画管线，已达标图片可复用原字节。
/// 可注入处理器，但其输出同样受到统一体积上限约束。
final class MomentImagePreprocessor {
  /// 直接注入整条处理管线（测试用，绕过真实解码器）。
  MomentImagePreprocessor.functional(this._processFn) : _compressBytes = null;

  MomentImagePreprocessor({
    Future<Uint8List?> Function(
      Uint8List bytes, {
      required int minWidth,
      required int minHeight,
      required int quality,
    })? compressBytes,
  })  : _compressBytes = compressBytes,
        _processFn = null;

  final Future<Uint8List?> Function(
    Uint8List bytes, {
    required int minWidth,
    required int minHeight,
    required int quality,
  })? _compressBytes;
  final Future<Uint8List> Function(Uint8List bytes)? _processFn;

  static const qualityLadder = [85, 70, 55];

  Future<Uint8List> process(Uint8List bytes) async {
    try {
      if (_processFn != null || _compressBytes != null) {
        return await MediaAssetGateway.prepareImage(bytes,
            transform: _processFn ?? _process);
      }
      return await ImageCompressionPolicy.prepare(bytes);
    } on FormatException catch (error) {
      throw MomentImageException(error.message);
    }
  }

  Future<Uint8List> _process(Uint8List bytes) async {
    final ({int width, int height}) target;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          target = targetDimensions(
              frame.image.width, frame.image.height, maxMomentImageEdge);
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
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
    throw const MomentImageException('图片压缩后仍超过体积上限，请缩小图片后重试');
  }
}
