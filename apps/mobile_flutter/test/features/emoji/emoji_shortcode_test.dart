import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/emoji/emoji_shortcode.dart';

void main() {
  test('🥲 按应用内映射表转换为 [微笑]', () {
    expect(emojiToShortcodes('🥲🥲你好'), '[微笑][微笑]你好');
  });

  test('普通文字、数字、标点、空格、换行不被转换', () {
    const text = 'Hello 123，你好！ \nline2 [abc]';
    expect(emojiToShortcodes(text), text);
  });

  test('已存在的 [xxx] 文本不会被二次转换', () {
    expect(emojiToShortcodes('[微笑][他]'), '[微笑][他]');
  });

  test('目录内 emoji 转换、目录外字符原样保留', () {
    // 😀 在目录内；🫸（目录外）保持原样不丢失。
    expect(emojiToShortcodes('😀好'), '[咧嘴]好');
    expect(emojiToShortcodes('🫸好'), '🫸好');
  });

  test('空字符串与纯 emoji 混排换行保持结构', () {
    expect(emojiToShortcodes(''), '');
    expect(emojiToShortcodes('👍\n👎'), '[赞]\n[踩]');
  });
}
