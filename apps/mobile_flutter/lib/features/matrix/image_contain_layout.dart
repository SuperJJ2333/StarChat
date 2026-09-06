import 'dart:math' as math;
import 'dart:ui';

/// 任意比例图片完整展示的布局计算（规格 #10）。
///
/// - 不使用固定比例白名单：按 EXIF 纠正后的实际宽高动态布局；
/// - 等比 contain：scale = min(maxW/w, maxH/h)，禁止 cover/拉伸/裁剪；
/// - 小图不放大（minScale=1，避免模糊）；
/// - 输出保持原比例；极长/极宽完整缩入容器，剩余空间留白。
final class ImageContainLayout {
  const ImageContainLayout({
    required this.width,
    required this.height,
  });

  /// 显示尺寸（保持原比例）。
  final double width;
  final double height;

  Size get size => Size(width, height);
}

/// 气泡图片约束：宽 ≤ min(可用聊天宽 72%, 320dp)；高 ≤ min(可用高 45%, 420dp)。
final class ChatBubbleImageConstraints {
  const ChatBubbleImageConstraints({
    required this.availableWidth,
    required this.availableHeight,
  });

  final double availableWidth;
  final double availableHeight;

  double get maxWidth => math.min(availableWidth * 0.72, 320);
  double get maxHeight => math.min(availableHeight * 0.45, 420);
}

/// 网格单元约束（三列网格统一外框；框内完整适配不裁切）。
final class MediaGridCellConstraints {
  const MediaGridCellConstraints(this.cellSize);
  final double cellSize;
}

/// contain 缩放计算（规格核心公式）。
///
/// [imageWidth]/[imageHeight] 为 EXIF 纠正后的实际像素；
/// [allowUpscale] 默认 false：小图不放大（显示原始尺寸，容器留白）。
ImageContainLayout computeContainLayout({
  required double imageWidth,
  required double imageHeight,
  required double maxWidth,
  required double maxHeight,
  bool allowUpscale = false,
}) {
  assert(imageWidth > 0 && imageHeight > 0, '需要解码后的实际宽高');
  final scaleByWidth = maxWidth / imageWidth;
  final scaleByHeight = maxHeight / imageHeight;
  var scale = math.min(scaleByWidth, scaleByHeight);
  if (!allowUpscale) scale = math.min(scale, 1.0);
  return ImageContainLayout(
    width: imageWidth * scale,
    height: imageHeight * scale,
  );
}

/// 网格单元 contain（同公式；外框统一尺寸，图片在框内完整适配）。
ImageContainLayout computeGridCellContain({
  required double imageWidth,
  required double imageHeight,
  required double cellSize,
  bool allowUpscale = true,
}) =>
    computeContainLayout(
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      maxWidth: cellSize,
      maxHeight: cellSize,
      allowUpscale: allowUpscale,
    );

/// EXIF 方向纠正（1=正常；6=顺时针 90°；8=逆时针 90°；3=180°）。
Size applyExifOrientation(int exifOrientation, int width, int height) {
  return switch (exifOrientation) {
    5 || 6 || 7 || 8 => Size(height.toDouble(), width.toDouble()),
    _ => Size(width.toDouble(), height.toDouble()),
  };
}

/// 大图查看器缩放/平移边界（初始 contain → 双击放大 → 平移钳制）。
final class ImageViewportBounds {
  const ImageViewportBounds({
    required this.minScale,
    required this.maxScale,
    required this.contentSize,
    required this.viewportSize,
  });

  final double minScale;
  final double maxScale;
  final Size contentSize;
  final Size viewportSize;

  /// 初始 contain 比例（小图 ≥1 不缩小为初始？——查看器允许缩小查看全图，
  /// 初始即 contain）。
  double get initialScale {
    final contain = math.min(
      viewportSize.width / contentSize.width,
      viewportSize.height / contentSize.height,
    );
    return contain;
  }

  /// 平移钳制：缩放后内容超出视口的部分为可平移范围。
  Offset clampPan(Offset offset, double scale) {
    final scaled = contentSize * scale;
    final maxX = math.max(0.0, (scaled.width - viewportSize.width) / 2);
    final maxY = math.max(0.0, (scaled.height - viewportSize.height) / 2);
    return Offset(
      offset.dx.clamp(-maxX, maxX),
      offset.dy.clamp(-maxY, maxY),
    );
  }
}
