import 'package:characters/characters.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_emoji_catalog.dart';
import 'package:liuhetong_mobile/features/emoji/fluent_vector_emoji_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vector catalog exposes unique chars and assets', () {
    final chars = vectorEmojis.map((emoji) => emoji.char).toSet();
    final assets = vectorEmojis.map((emoji) => emoji.asset).toSet();
    expect(chars.length, vectorEmojis.length);
    expect(assets.length, vectorEmojis.length);
    for (final emoji in vectorEmojis) {
      expect(emoji.asset, startsWith('assets/emoji_vector/'));
      expect(emoji.asset, endsWith('.svg'));
      expect(emoji.char.characters, hasLength(1));
    }
  });

  test('vector catalog covers every animated fluent emoji char', () {
    for (final emoji in fluentEmojis) {
      final vector = vectorEmojiByChar(emoji.char);
      expect(vector, isNotNull, reason: 'missing vector emoji for ${emoji.char}');
    }
  });

  test('lookup by unicode char strips the emoji presentation selector', () {
    expect(vectorEmojiByChar('❤️'), vectorEmojiByChar('❤'));
    expect(vectorEmojiByChar('⭐'), isNotNull);
    expect(vectorEmojiByChar('未知'), isNull);
  });

  test('every bundled vector emoji resolves by its own char', () {
    for (final emoji in vectorEmojis) {
      expect(vectorEmojiByChar(emoji.char), same(emoji));
    }
  });

  test('bundled svg assets are loadable', () async {
    for (final emoji in vectorEmojis.take(30)) {
      final data = await rootBundle.load(emoji.asset);
      expect(data.lengthInBytes, greaterThan(0), reason: emoji.asset);
    }
  });
}
