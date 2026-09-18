import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/image_crop_geometry.dart';

/// 视图空间：300×200 的图片矩形，四周留白。
const _bounds = Rect.fromLTWH(50, 40, 300, 200);
final _full = _bounds;

void main() {
  group('命中测试', () {
    test('四角优先于四边', () {
      expect(ImageCropGeometry.handleAt(_full, _full.topLeft),
          CropHandle.topLeft);
      expect(ImageCropGeometry.handleAt(_full, _full.topRight),
          CropHandle.topRight);
      expect(ImageCropGeometry.handleAt(_full, _full.bottomLeft),
          CropHandle.bottomLeft);
      expect(ImageCropGeometry.handleAt(_full, _full.bottomRight),
          CropHandle.bottomRight);
    });

    test('四边中点可命中，框内与框外不命中', () {
      expect(
          ImageCropGeometry.handleAt(
              _full, Offset(_full.center.dx, _full.top)),
          CropHandle.top);
      expect(
          ImageCropGeometry.handleAt(
              _full, Offset(_full.center.dx, _full.bottom)),
          CropHandle.bottom);
      expect(
          ImageCropGeometry.handleAt(
              _full, Offset(_full.left, _full.center.dy)),
          CropHandle.left);
      expect(
          ImageCropGeometry.handleAt(
              _full, Offset(_full.right, _full.center.dy)),
          CropHandle.right);
      expect(ImageCropGeometry.handleAt(_full, _full.center), CropHandle.none);
      expect(ImageCropGeometry.handleAt(_full, Offset(_full.right + 80, 0)),
          CropHandle.none);
    });
  });

  group('拖动求解', () {
    test('拖动四角同时改变两条边', () {
      final next = ImageCropGeometry.resize(
        frame: _full,
        handle: CropHandle.topLeft,
        delta: const Offset(60, 40),
        bounds: _bounds,
      );
      expect(next.left, closeTo(_full.left + 60, .01));
      expect(next.top, closeTo(_full.top + 40, .01));
      expect(next.right, _full.right);
      expect(next.bottom, _full.bottom);
    });

    test('拖动四边只改变一条边', () {
      final top = ImageCropGeometry.resize(
          frame: _full,
          handle: CropHandle.top,
          delta: const Offset(999, 30),
          bounds: _bounds);
      expect(top.top, closeTo(_full.top + 30, .01));
      expect(top.left, _full.left);
      expect(top.right, _full.right);
      expect(top.bottom, _full.bottom);

      final right = ImageCropGeometry.resize(
          frame: _full,
          handle: CropHandle.right,
          delta: const Offset(-40, 999),
          bounds: _bounds);
      expect(right.right, closeTo(_full.right - 40, .01));
      expect(right.top, _full.top);
      expect(right.bottom, _full.bottom);
    });

    test('最小尺寸：内收到阈值后不再变化', () {
      final next = ImageCropGeometry.resize(
        frame: _full,
        handle: CropHandle.topLeft,
        delta: const Offset(9999, 9999),
        bounds: _bounds,
      );
      expect(next.width, greaterThanOrEqualTo(ImageCropGeometry.minFrameSize));
      expect(next.height, greaterThanOrEqualTo(ImageCropGeometry.minFrameSize));
    });

    test('裁剪框不会越出图片矩形', () {
      final next = ImageCropGeometry.resize(
        frame: _full,
        handle: CropHandle.topLeft,
        delta: const Offset(-999, -999),
        bounds: _bounds,
      );
      expect(next.left, closeTo(_bounds.left, .01));
      expect(next.top, closeTo(_bounds.top, .01));
      expect(ImageCropGeometry.withinBounds(next, _bounds), isTrue);
    });

    test('固定比例：拖动角时保持宽高比', () {
      final next = ImageCropGeometry.resize(
        frame: _full,
        handle: CropHandle.bottomRight,
        delta: const Offset(-120, -40),
        bounds: _bounds,
        aspect: 1,
      );
      expect(next.width / next.height, closeTo(1, .01));
      expect(next.topLeft, _full.topLeft, reason: '对侧锚点不动');
    });

    test('固定比例：拖动边时保持宽高比并居中', () {
      final next = ImageCropGeometry.resize(
        frame: _full,
        handle: CropHandle.left,
        delta: const Offset(80, 0),
        bounds: _bounds,
        aspect: 1,
      );
      expect(next.width / next.height, closeTo(1, .01));
      expect(next.center.dy, closeTo(_full.center.dy, .01));
    });

    test('切换比例以中心为锚点套用宽高比', () {
      final next = ImageCropGeometry.applyAspect(_full, 1, _bounds);
      expect(next.width / next.height, closeTo(1, .01));
      expect(next.center.dx, closeTo(_full.center.dx, .01));
      expect(next.center.dy, closeTo(_full.center.dy, .01));
      expect(ImageCropGeometry.withinBounds(next, _bounds), isTrue);

      final wide = ImageCropGeometry.applyAspect(_full, 16 / 9, _bounds);
      expect(wide.width / wide.height, closeTo(16 / 9, .01));
      expect(wide.width, lessThanOrEqualTo(_bounds.width + .01));
    });
  });

  group('视图 → 图像坐标', () {
    test('整图裁剪框映射回整张图片', () {
      final rect = ImageCropGeometry.toImageRect(
        frame: _bounds,
        imageViewRect: _bounds,
        imageBounds: const Rect.fromLTWH(0, 0, 100, 100),
      );
      expect(rect, const Rect.fromLTWH(0, 0, 100, 100));
    });

    test('半幅裁剪框映射到图像中央一半', () {
      final rect = ImageCropGeometry.toImageRect(
        frame: Rect.fromLTWH(_bounds.left + 75, _bounds.top + 50, 150, 100),
        imageViewRect: _bounds,
        imageBounds: const Rect.fromLTWH(0, 0, 200, 200),
      );
      expect(rect.left, closeTo(50, .01));
      expect(rect.top, closeTo(50, .01));
      expect(rect.width, closeTo(100, .01));
      expect(rect.height, closeTo(100, .01));
    });

    test('退化输入返回整张图片而不是空矩形', () {
      final rect = ImageCropGeometry.toImageRect(
        frame: _bounds,
        imageViewRect: Rect.zero,
        imageBounds: const Rect.fromLTWH(0, 0, 40, 30),
      );
      expect(rect, const Rect.fromLTWH(0, 0, 40, 30));
    });
  });
}
