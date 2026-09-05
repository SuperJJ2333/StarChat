import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:liuhetong_mobile/features/moments/moment_composer_page.dart';

void main() {
  group('朋友圈图片候选过滤（Media Picker 修复，需求 10/11）', () {
    XFile fileOf(String name, {String? mime}) =>
        XFile('${Directory.systemTemp.path}/$name', name: name, mimeType: mime);

    test('accepts image mimes: jpg/png/webp/gif', () {
      for (final mime in ['image/jpeg', 'image/png', 'image/webp', 'image/gif']) {
        expect(isSupportedMomentImage(fileOf('a', mime: mime)), isTrue,
            reason: mime);
      }
    });

    test('rejects video mimes: mp4/mov/hevc', () {
      for (final mime in ['video/mp4', 'video/quicktime', 'video/hevc']) {
        expect(isSupportedMomentImage(fileOf('a', mime: mime)), isFalse,
            reason: mime);
      }
    });

    test('falls back to extension when mime missing', () {
      expect(isSupportedMomentImage(fileOf('photo.JPG')), isTrue);
      expect(isSupportedMomentImage(fileOf('photo.png')), isTrue);
      expect(isSupportedMomentImage(fileOf('clip.mp4')), isFalse);
      expect(isSupportedMomentImage(fileOf('clip.mov')), isFalse);
      expect(isSupportedMomentImage(fileOf('clip.hevc')), isFalse);
      expect(isSupportedMomentImage(fileOf('noext')), isFalse);
    });
  });
}
