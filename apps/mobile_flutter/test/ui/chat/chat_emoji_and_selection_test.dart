import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text_controller.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text.dart';
import 'package:liuhetong_mobile/ui/chat/message_highlight_pulse.dart';
import 'package:liuhetong_mobile/ui/chat/quote_return_banner.dart';

void main() {
  testWidgets('输入框控制器把目录内 emoji 渲染为彩色字形（与气泡一致）',
      (tester) async {
    final controller = EmojiEditingController(text: 'a🥲b');
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: CupertinoTextField(controller: controller),
        ),
      ),
    );
    await tester.pump();

    // 🥲 在动态目录中：输入框内出现与气泡相同的动态字形 WidgetSpan。
    expect(find.byType(EmojiAnimatedGlyph), findsOneWidget);
    // 文本内容保持不变：光标/选区/发送路径仍操作原始字符串。
    expect(controller.text, 'a🥲b');
  });

  testWidgets('输入框普通文本走快速路径（无 WidgetSpan）', (tester) async {
    final controller = EmojiEditingController(text: 'abc');
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: CupertinoTextField(controller: controller),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(EmojiAnimatedGlyph), findsNothing);
    expect(find.byType(EmojiVectorGlyph), findsNothing);
    expect(find.text('abc'), findsOneWidget);
  });

  testWidgets('回到引用位置弹窗：渲染并与 @提醒弹窗同款交互', (tester) async {
    var tapped = false;
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(child: QuoteReturnBannerButton(onTap: () => tapped = true)),
      ),
    ));
    expect(find.text('回到引用位置'), findsOneWidget);
    expect(find.byKey(const Key('quote-return-banner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quote-return-banner')));
    expect(tapped, isTrue);
  });

  testWidgets('消息高亮脉冲结束后不残留背景', (tester) async {
    const childKey = Key('pulse-child');
    await tester.pumpWidget(CupertinoApp(
      home: MessageHighlightPulse(
        active: true,
        child: const SizedBox(key: childKey, width: 100, height: 40),
      ),
    ));
    final fadeTransition = tester.widget<FadeTransition>(
      find.ancestor(
          of: find.byKey(childKey), matching: find.byType(FadeTransition)),
    );
    // 淡入 120ms 后处于可见阶段。
    await tester.pump(const Duration(milliseconds: 60));
    expect(fadeTransition.opacity.value, greaterThan(0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // 序列走完（1500ms）后不透明度归零：无残留。
    expect(fadeTransition.opacity.value, 0.0);
  });
}
