import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:video_compress/video_compress.dart';

/// 视频帧获取器（path + 毫秒位置 → JPEG 字节；测试注入用）。
typedef VideoFrameFetcher =
    Future<Uint8List?> Function(String path, int positionMs);

/// 多时间点视频封面抽取 + 近黑帧检测（BUG 修复：视频消息无封面/黑卡）。
///
/// 旧实现单点 `thumbnailDataWithSize` 常取到片头黑帧（大量视频前几百
/// 毫秒为黑场），接收端整卡黑块。这里依序在 [200, 500, 1000, 2000]ms
/// 抽帧（video_compress getByteThumbnail 支持毫秒位置），平均亮度
/// < [blackLumaThreshold] 视为近黑帧跳过；全部失败返回 null，调用方
/// 回退原有 photo_manager 封面或占位图。
Future<Uint8List?> extractVideoPoster(
  String videoPath, {
  VideoFrameFetcher? fetch,
  List<int> positionsMs = const [200, 500, 1000, 2000],
  double blackLumaThreshold = 16,
}) async {
  final getFrame = fetch ??
      (path, positionMs) =>
          VideoCompress.getByteThumbnail(path, quality: 85, position: positionMs);
  for (final positionMs in positionsMs) {
    try {
      final bytes = await getFrame(videoPath, positionMs);
      if (bytes == null || bytes.isEmpty) continue;
      final luma = await frameAverageLuma(bytes);
      if (luma >= blackLumaThreshold) return bytes;
    } catch (error) {
      // 单点失败（解码器不支持/文件忙）继续下一时间点。
      debugPrint('[video-poster] frame at ${positionMs}ms failed: $error');
    }
  }
  return null;
}

/// 帧平均亮度（0-255）。
///
/// 以 32px 宽解码采样（高度等比），全通道 BT.601 加权——足以区分黑场
/// 与正常画面，无需全尺寸解码。
Future<double> frameAverageLuma(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded, targetWidth: 32);
  try {
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null || data.lengthInBytes < 4) return 255;
    final pixels = data.lengthInBytes ~/ 4;
    var total = 0.0;
    for (var i = 0; i < pixels; i++) {
      final o = i * 4;
      // BT.601 亮度。
      total +=
          0.299 * data.getUint8(o) + 0.587 * data.getUint8(o + 1) + 0.114 * data.getUint8(o + 2);
    }
    frame.image.dispose();
    return total / pixels;
  } finally {
    codec.dispose();
  }
}
