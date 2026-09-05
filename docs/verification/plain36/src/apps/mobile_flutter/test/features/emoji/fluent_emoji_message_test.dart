import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog exposes a reverse lookup by unicode character', () {
    final joy = fluentEmojiByChar('😂');
    expect(joy, isNotNull);
    expect(joy!.asset, 'assets/emoji/joy.webp');
    expect(fluentEmojiByChar('🚀'), isNotNull);
    expect(fluentEmojiByChar('未知字符'), isNull);
  });

  test('animated assets are high-resolution WebP with smooth alpha', () async {
    // 毛刺修复回归：资产必须为源分辨率（≥192px）的 animated WebP，
    // 杜绝 72px GIF（1-bit 二值透明）再次进入渲染管线被放大产生锯齿。
    for (final emoji in fluentEmojis) {
      expect(emoji.asset, endsWith('.webp'), reason: emoji.asset);
      final data = await rootBundle.load(emoji.asset);
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      expect(frame.image.width, greaterThanOrEqualTo(192), reason: emoji.asset);
      expect(frame.image.height, greaterThanOrEqualTo(192), reason: emoji.asset);
      frame.image.dispose();
      codec.dispose();
    }
  });

  test('pure emoji message detection', () {
    expect(fluentEmojisInMessage('😂'), hasLength(1));
    expect(fluentEmojisInMessage(' 😄 🚀 '), hasLength(2));
    expect(fluentEmojisInMessage('😂😄😊🥳'), hasLength(4));
  });

  test('mixed text or unknown chars render as plain text', () {
    expect(fluentEmojisInMessage('你好😂'), isEmpty);
    expect(fluentEmojisInMessage('普通消息'), isEmpty);
    expect(fluentEmojisInMessage(''), isEmpty);
  });

  test('more than four emojis render as plain text', () {
    expect(fluentEmojisInMessage('😂😄😊🥳🚀'), isEmpty);
  });

  test('catalog lookup covers every bundled emoji exactly once', () {
    final chars = fluentEmojis.map((emoji) => emoji.char).toSet();
    expect(chars.length, fluentEmojis.length);
    for (final emoji in fluentEmojis) {
      expect(fluentEmojiByChar(emoji.char), isNotNull);
    }
  });
}
