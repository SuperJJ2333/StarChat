import 'package:flutter/painting.dart';

/// 裁剪框的可拖拽位置：四角 + 四边。
enum CropHandle {
  none,
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left;

  bool get isCorner =>
      this == topLeft ||
      this == topRight ||
      this == bottomRight ||
      this == bottomLeft;

  bool get movesLeft =>
      this == topLeft || this == bottomLeft || this == left;

  bool get movesRight =>
      this == topRight || this == bottomRight || this == right;

  bool get movesTop => this == topLeft || this == topRight || this == top;

  bool get movesBottom =>
      this == bottomLeft || this == bottomRight || this == bottom;
}

/// 裁剪框几何（视图 / 画布空间，纯函数，可单测）。
///
/// 设计要点（对齐微信图片编辑）：
/// - 默认裁剪框**覆盖整个图片**（调用方传入图片在画布中的矩形）；
/// - 四角与四边都可拖动，最小尺寸 [minFrameSize] 防止框塌陷；
/// - 裁剪框始终被夹在图片矩形 [bounds] 内，不会裁出空白；
/// - 支持固定宽高比与自由裁剪两种模式。
abstract final class ImageCropGeometry {
  /// 手指命中边框的容差（视图像素）：明显大于视觉线宽，保证好按。
  static const double handleHitSlop = 24;

  /// 裁剪框最小边长（视图像素）：低于此值无法继续内收。
  static const double minFrameSize = 56;

  /// 命中测试：返回最接近 [point] 的可拖拽位置。
  ///
  /// 角优先于边（角上同时命中时给角），符合「四角控制点更醒目」的直觉。
  static CropHandle handleAt(Rect frame,
      Offset point, {
    double slop = handleHitSlop,
  }) {
    if (frame.isEmpty) return CropHandle.none;
    final nearLeft = (point.dx - frame.left).abs() <= slop;
    final nearRight = (point.dx - frame.right).abs() <= slop;
    final nearTop = (point.dy - frame.top).abs() <= slop;
    final nearBottom = (point.dy - frame.bottom).abs() <= slop;
    final insideX = point.dx >= frame.left - slop &&
        point.dx <= frame.right + slop;
    final insideY = point.dy >= frame.top - slop &&
        point.dy <= frame.bottom + slop;
    if (!insideX || !insideY) return CropHandle.none;
    if (nearLeft && nearTop) return CropHandle.topLeft;
    if (nearRight && nearTop) return CropHandle.topRight;
    if (nearRight && nearBottom) return CropHandle.bottomRight;
    if (nearLeft && nearBottom) return CropHandle.bottomLeft;
    if (nearTop && point.dx > frame.left && point.dx < frame.right) {
      return CropHandle.top;
    }
    if (nearBottom && point.dx > frame.left && point.dx < frame.right) {
      return CropHandle.bottom;
    }
    if (nearLeft && point.dy > frame.top && point.dy < frame.bottom) {
      return CropHandle.left;
    }
    if (nearRight && point.dy > frame.top && point.dy < frame.bottom) {
      return CropHandle.right;
    }
    return CropHandle.none;
  }

  /// 拖动 [handle] 之后的裁剪框。
  ///
  /// [delta] 是本次手势在视图空间的位移；[bounds] 是图片当前可见矩形；
  /// [aspect]（宽/高）非空时保持比例，为空表示自由裁剪。
  static Rect resize({
    required Rect frame,
    required CropHandle handle,
    required Offset delta,
    required Rect bounds,
    double minSize = minFrameSize,
    double? aspect,
  }) {
    if (handle == CropHandle.none || frame.isEmpty || bounds.isEmpty) {
      return frame;
    }
    var left = frame.left;
    var right = frame.right;
    var top = frame.top;
    var bottom = frame.bottom;
    if (handle.movesLeft) {
      left = (frame.left + delta.dx)
          .clamp(bounds.left, frame.right - minSize);
    }
    if (handle.movesRight) {
      right = (frame.right + delta.dx)
          .clamp(frame.left + minSize, bounds.right);
    }
    if (handle.movesTop) {
      top = (frame.top + delta.dy).clamp(bounds.top, frame.bottom - minSize);
    }
    if (handle.movesBottom) {
      bottom = (frame.bottom + delta.dy)
          .clamp(frame.top + minSize, bounds.bottom);
    }
    final candidate = Rect.fromLTRB(left, top, right, bottom);
    if (candidate.width < minSize || candidate.height < minSize) return frame;
    var next = candidate;
    if (aspect != null && aspect > 0) {
      final fitted = _withAspect(candidate, aspect, handle, bounds, minSize);
      if (fitted == null) return frame;
      next = fitted;
    }
    if (!_within(next, bounds)) return frame;
    return next;
  }

  /// 以 [frame] 的中心为锚点套用固定宽高比（切换比例时使用），
  /// 超出 [bounds] 时先缩小再居中夹取。
  static Rect applyAspect(Rect frame, double aspect, Rect bounds,
      {double minSize = minFrameSize}) {
    if (aspect <= 0 || frame.isEmpty || bounds.isEmpty) return frame;
    var width = frame.width;
    var height = width / aspect;
    if (height > frame.height) {
      height = frame.height;
      width = height * aspect;
    }
    if (width > bounds.width) {
      width = bounds.width;
      height = width / aspect;
    }
    if (height > bounds.height) {
      height = bounds.height;
      width = height * aspect;
    }
    if (width < minSize || height < minSize) return frame;
    final center = frame.center;
    return _shiftInto(
        Rect.fromCenter(center: center, width: width, height: height), bounds);
  }

  /// 保证矩形完整落在 [bounds] 内（保持尺寸，必要时平移；放不下则居中夹取）。
  static Rect _shiftInto(Rect rect, Rect bounds) {
    if (_within(rect, bounds)) return rect;
    final width = rect.width.clamp(0.0, bounds.width);
    final height = rect.height.clamp(0.0, bounds.height);
    final dx = rect.left.clamp(bounds.left, (bounds.right - width).clamp(bounds.left, bounds.right));
    final dy = rect.top.clamp(bounds.top, (bounds.bottom - height).clamp(bounds.top, bounds.bottom));
    return Rect.fromLTWH(dx, dy, width, height);
  }

  static bool _within(Rect rect, Rect bounds) =>
      rect.left >= bounds.left - .01 &&
      rect.top >= bounds.top - .01 &&
      rect.right <= bounds.right + .01 &&
      rect.bottom <= bounds.bottom + .01;

  /// 固定比例下的候选框：以拖动边/角的**对侧**为锚点，保证不漂移。
  static Rect? _withAspect(Rect frame, double aspect, CropHandle handle,
      Rect bounds, double minSize) {
    final horizontal = handle.movesLeft || handle.movesRight;
    final vertical = handle.movesTop || handle.movesBottom;
    if (!horizontal && !vertical) return frame;
    if (horizontal && vertical) {
      final anchor = Offset(
          handle.movesLeft ? frame.right : frame.left,
          handle.movesTop ? frame.bottom : frame.top);
      // 锚点 → 被拖动边的距离（不是整框的宽高）。
      var width = handle.movesLeft ? anchor.dx - frame.left : frame.right - anchor.dx;
      var height =
          handle.movesTop ? anchor.dy - frame.top : frame.bottom - anchor.dy;
      if (width <= 0 || height <= 0) return null;
      // 取「更想变大」的那个方向，手感上跟手。
      if (width / height > aspect) {
        height = width / aspect;
      } else {
        width = height * aspect;
      }
      final maxWidth = handle.movesLeft
          ? anchor.dx - bounds.left
          : bounds.right - anchor.dx;
      final maxHeight = handle.movesTop
          ? anchor.dy - bounds.top
          : bounds.bottom - anchor.dy;
      var scale = 1.0;
      if (width > maxWidth) scale = maxWidth / width;
      if (height * scale > maxHeight) scale = maxHeight / height;
      width *= scale;
      height *= scale;
      if (width < minSize || height < minSize) return null;
      final left = handle.movesLeft ? anchor.dx - width : anchor.dx;
      final top = handle.movesTop ? anchor.dy - height : anchor.dy;
      return Rect.fromLTWH(left, top, width, height);
    }
    if (horizontal) {
      var width = frame.width;
      var height = width / aspect;
      final centerY = frame.center.dy;
      final maxHeight = 2 *
          (centerY - bounds.top < bounds.bottom - centerY
              ? centerY - bounds.top
              : bounds.bottom - centerY);
      if (height > maxHeight) {
        height = maxHeight;
        width = height * aspect;
      }
      if (width > bounds.width) {
        width = bounds.width;
        height = width / aspect;
      }
      if (width < minSize || height < minSize) return null;
      return Rect.fromCenter(
          center: Offset(frame.center.dx, centerY),
          width: width,
          height: height);
    }
    var height = frame.height;
    var width = height * aspect;
    final centerX = frame.center.dx;
    final maxWidth = 2 *
        (centerX - bounds.left < bounds.right - centerX
            ? centerX - bounds.left
            : bounds.right - centerX);
    if (width > maxWidth) {
      width = maxWidth;
      height = width / aspect;
    }
    if (height > bounds.height) {
      height = bounds.height;
      width = height * aspect;
    }
    if (width < minSize || height < minSize) return null;
    return Rect.fromCenter(
        center: Offset(centerX, frame.center.dy),
        width: width,
        height: height);
  }

  /// 视图矩形 → 图像像素矩形：把裁剪框映射回原图坐标（应用裁剪时使用）。
  static Rect toImageRect({
    required Rect frame,
    required Rect imageViewRect,
    required Rect imageBounds,
  }) {
    if (imageViewRect.width <= 0 || imageViewRect.height <= 0) {
      return imageBounds;
    }
    final scaleX = imageBounds.width / imageViewRect.width;
    final scaleY = imageBounds.height / imageViewRect.height;
    final left =
        imageBounds.left + (frame.left - imageViewRect.left) * scaleX;
    final top = imageBounds.top + (frame.top - imageViewRect.top) * scaleY;
    final right = imageBounds.left + (frame.right - imageViewRect.left) * scaleX;
    final bottom =
        imageBounds.top + (frame.bottom - imageViewRect.top) * scaleY;
    final rect = Rect.fromLTRB(left, top, right, bottom).intersect(imageBounds);
    if (rect.width < 1 || rect.height < 1) return imageBounds;
    return rect;
  }

  /// 矩形是否完整落在 [bounds] 内（调用方用于判断布局/文档变化后
  /// 裁剪框是否仍有效）。
  static bool withinBounds(Rect rect, Rect bounds) => _within(rect, bounds);
}
