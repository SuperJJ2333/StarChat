import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/notification/sound_type.dart';

void main() {
  group('SoundType 音效资产完整性', () {
    test('每个 SoundType 都有对应的 assets/sounds 文件（顶替文件不得漏放）', () {
      for (final type in SoundType.values) {
        final file = File(type.assetPath);
        expect(
          file.existsSync(),
          isTrue,
          reason: '缺少音效资产：${type.assetPath}',
        );
        // 空文件或占位文件视为缺失。
        if (file.existsSync()) {
          expect(file.lengthSync(), greaterThan(1024),
              reason: '音效资产异常过小：${type.assetPath}');
        }
      }
    });

    test('assetPath 统一指向 assets/sounds/ 目录', () {
      for (final type in SoundType.values) {
        expect(type.assetPath.startsWith('assets/sounds/'), isTrue);
      }
    });
  });
}
