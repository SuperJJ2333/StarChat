import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/image_contain_layout.dart';

/// 规格 #10：任意比例图片完整展示。
void main() {
  // 屏幕约束：宽 400 可用（→ 上限 min(288, 320)=288）、高 800 可用
  // （→ 上限 min(360, 420)=360）。
  const constraints =
      ChatBubbleImageConstraints(availableWidth: 400, availableHeight: 800);

  double ratio(ImageContainLayout l) => l.width / l.height;

  group('常用比例完整缩入（无裁剪、无失真）', () {
    for (final (w, h) in [
      (1000, 1000), // 1:1
      (1200, 800), // 3:2
      (800, 1200), // 2:3
      (1024, 768), // 4:3
      (768, 1024), // 3:4
      (1280, 720), // 16:9
      (720, 1280), // 9:16
      (1440, 720), // 18:9
    ]) {
      test('$w x $h 完整适配', () {
        final layout = computeContainLayout(
          imageWidth: w.toDouble(),
          imageHeight: h.toDouble(),
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
        );
        expect(layout.width, lessThanOrEqualTo(constraints.maxWidth + 0.001));
        expect(layout.height, lessThanOrEqualTo(constraints.maxHeight + 0.001));
        // 比例保持（原比例的 1e-9 内）。
        expect(ratio(layout), closeTo(w / h, (w / h) * 1e-9));
      });
    }
  });

  group('极端比例与不规则尺寸', () {
    test('1:10 极长图完整缩入（高度触顶，宽度留白）', () {
      final layout = computeContainLayout(
        imageWidth: 100,
        imageHeight: 1000,
        maxWidth: constraints.maxWidth,
        maxHeight: constraints.maxHeight,
      );
      expect(layout.height, closeTo(constraints.maxHeight, 0.001));
      expect(layout.width, closeTo(constraints.maxHeight / 10, 0.001),
          reason: '宽度 = 360/10 = 36，剩余留白');
    });

    test('10:1 极宽图完整缩入', () {
      final layout = computeContainLayout(
        imageWidth: 1000,
        imageHeight: 100,
        maxWidth: constraints.maxWidth,
        maxHeight: constraints.maxHeight,
      );
      expect(layout.width, lessThanOrEqualTo(constraints.maxWidth + 0.001));
      expect(ratio(layout), closeTo(10, 1e-9));
    });

    test('EXIF 方向纠正：orientation 6（90°）宽高互换后布局', () {
      final corrected =
          applyExifOrientation(6, 800, 1200); // 拍摄 800x1200 + 旋转 90°。
      expect(corrected, const Size(1200, 800));
      final layout = computeContainLayout(
        imageWidth: corrected.width,
        imageHeight: corrected.height,
        maxWidth: constraints.maxWidth,
        maxHeight: constraints.maxHeight,
      );
      expect(ratio(layout), closeTo(1200 / 800, 1e-9));
    });
  });

  group('小图不放大 / 上限', () {
    test('小图（120x90）显示原始尺寸，不放大', () {
      final layout = computeContainLayout(
        imageWidth: 120,
        imageHeight: 90,
        maxWidth: constraints.maxWidth,
        maxHeight: constraints.maxHeight,
      );
      expect(layout.width, 120);
      expect(layout.height, 90);
    });

    test('气泡上限：宽 72% 与 320dp 取小；高 45% 与 420dp 取小', () {
      expect(constraints.maxWidth, 288, reason: 'min(400*0.72=288, 320)');
      expect(constraints.maxHeight, 360, reason: 'min(800*0.45=360, 420)');
      // 大屏：上限取 320/420。
      const big = ChatBubbleImageConstraints(
          availableWidth: 600, availableHeight: 1200);
      expect(big.maxWidth, 320);
      expect(big.maxHeight, 420);
    });
  });

  group('网格单元与查看器', () {
    test('三列网格：外框统一，框内完整适配不裁切', () {
      final layout = computeGridCellContain(
          imageWidth: 800, imageHeight: 200, cellSize: 120);
      expect(layout.width, closeTo(120, 0.001));
      expect(layout.height, closeTo(30, 0.001), reason: '800:200 → 120:30');
      expect(ratio(layout), closeTo(4, 1e-9));
    });

    test('查看器：初始 contain、平移钳制在缩放范围内', () {
      final bounds = ImageViewportBounds(
        minScale: 1,
        maxScale: 4,
        contentSize: const Size(2000, 1000),
        viewportSize: const Size(400, 800),
      );
      expect(bounds.initialScale, closeTo(0.2, 1e-9), reason: 'min(0.2, 0.8)');
      // 放大 2 倍（0.4 相对原图）：内容 800x400，超宽 400 → x 可移 ±200。
      final clamped = bounds.clampPan(const Offset(999, 999), 0.4);
      expect(clamped.dx, 200);
      expect(clamped.dy, 0, reason: '高度 400<800 不可垂直平移');
    });
  });
}
