import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/device_gallery_source.dart';

/// 视频压缩策略与回退提示（需求一.2/一.3）：
/// - 压缩产物更小即采用；
/// - 未达 ≥50% 减量且原件 >10MB 时降档重试；
/// - 压缩不可用回退原始视频时必须带明确提示。
void main() {
  group('shouldRetryVideoAtLowerQuality', () {
    test('reaches >=50% reduction on large video: no retry', () {
      final retry = shouldRetryVideoAtLowerQuality(
        originalBytes: 20 * 1024 * 1024,
        compressedBytes: 9 * 1024 * 1024, // 55% 减量
      );
      expect(retry, isFalse);
    });

    test('below 50% reduction on large video: retry at lower quality', () {
      final retry = shouldRetryVideoAtLowerQuality(
        originalBytes: 20 * 1024 * 1024,
        compressedBytes: 12 * 1024 * 1024, // 40% 减量
      );
      expect(retry, isTrue);
    });

    test('small original video: never retry (quality first)', () {
      final retry = shouldRetryVideoAtLowerQuality(
        originalBytes: 1 * 1024 * 1024,
        compressedBytes: 900 * 1024,
      );
      expect(retry, isFalse);
    });

    test('compressed larger than original: retry on large video', () {
      final retry = shouldRetryVideoAtLowerQuality(
        originalBytes: 16 * 1024 * 1024,
        compressedBytes: 14 * 1024 * 1024,
      );
      expect(retry, isTrue);
    });

    test('non-positive original: no retry', () {
      expect(
        shouldRetryVideoAtLowerQuality(originalBytes: 0, compressedBytes: 100),
        isFalse,
      );
    });
  });

  group('VideoRendition fallback semantics', () {
    test('fallback carries explicit notice', () {
      final rendition = VideoRendition(
        file: File('unused'),
        usedCompressed: false,
        fallbackNotice: '压缩版不可用，已使用原始视频（12M）',
      );
      expect(rendition.usedCompressed, isFalse);
      expect(rendition.fallbackNotice, contains('压缩版不可用'));
      expect(rendition.fallbackNotice, contains('原始视频'));
      expect(rendition.compressionRatio, isNull);
    });

    test('compressed rendition carries ratio and no notice', () {
      final rendition = VideoRendition(
        file: File('unused'),
        usedCompressed: true,
        compressionRatio: 0.31,
      );
      expect(rendition.usedCompressed, isTrue);
      expect(rendition.fallbackNotice, isNull);
      expect(rendition.compressionRatio, lessThan(0.5));
    });
  });

  group('formatBytes', () {
    test('formats KB and MB', () {
      expect(formatBytes(512), '1K');
      expect(formatBytes(1500 * 1024), '1.5M');
      expect(formatBytes(25 * 1024 * 1024), '25M');
    });
  });
}
