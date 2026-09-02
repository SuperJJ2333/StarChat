import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text.dart';
Widget _host(String text) => CupertinoApp(
      home: CupertinoPageScaffold(
        child: EmojiText(text),
      ),
    );

void main() {
  testWidgets('plain text renders through the fast Text path', (tester) async {
    await tester.pumpWidget(_host('普通消息 hello'));
    await tester.pump();

    final text = tester.widget<Text>(find.byType(Text));
    expect(text.data, '普通消息 hello');
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('known emoji renders the inline ANIMATED glyph', (tester) async {
    // 混排动效：动态库收录的表情在文本流中持续播放（Animated WebP）。
    await tester.pumpWidget(_host('你好😂'));
    await tester.pumpAndSettle();

    expect(find.byType(EmojiAnimatedGlyph), findsOneWidget);
    final rich = tester.widget<Text>(find.byType(Text)).textSpan!
        as TextSpan;
    final spans = rich.children!;
    expect(spans, hasLength(2));
    expect((spans[0] as TextSpan).text, '你好');
    final widgetSpan = spans[1] as WidgetSpan;
    expect(widgetSpan.alignment, PlaceholderAlignment.middle);
    final glyph = widgetSpan.child as EmojiAnimatedGlyph;
    expect(glyph.asset, 'assets/emoji/joy.webp');
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(SvgPicture), findsNothing);
  });

  testWidgets('mixed text splits plain segments around each emoji',
      (tester) async {
    // 😂 命中动态库（WebP 动画），⭐ 回退矢量静态字形。
    await tester.pumpWidget(_host('a😂b⭐c'));
    await tester.pumpAndSettle();

    expect(find.byType(EmojiAnimatedGlyph), findsOneWidget);
    expect(find.byType(SvgPicture), findsOneWidget);
    final rich = tester.widget<Text>(find.byType(Text)).textSpan!
        as TextSpan;
    final spans = rich.children!;
    expect((spans[0] as TextSpan).text, 'a');
    expect(spans[1], isA<WidgetSpan>());
    expect((spans[2] as TextSpan).text, 'b');
    expect(spans[3], isA<WidgetSpan>());
    expect((spans[4] as TextSpan).text, 'c');
  });

  testWidgets('emoji with presentation selector resolves to the vector set',
      (tester) async {
    await tester.pumpWidget(_host('开头 ❤️ 结尾'));
    await tester.pumpAndSettle();

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('unknown emoji chars fall back to system text rendering',
      (tester) async {
    await tester.pumpWidget(_host('普通 🦣 消息'));
    await tester.pump();

    expect(find.byType(SvgPicture), findsNothing);
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.data, '普通 🦣 消息');
  });
}
