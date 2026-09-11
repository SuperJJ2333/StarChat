import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text_controller.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_composer.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text.dart';
import 'package:liuhetong_mobile/ui/chat/message_highlight_pulse.dart';
import 'package:liuhetong_mobile/ui/chat/quote_return_banner.dart';

RenderEditable _renderEditableFor(WidgetTester tester) {
  RenderEditable? result;
  void visit(RenderObject node) {
    if (node is RenderEditable) {
      result = node;
      return;
    }
    node.visitChildren(visit);
  }

  visit(tester.element(find.byType(EditableText)).findRenderObject()!);
  return result!;
}

void main() {
  testWidgets(
      'attached WeChatComposer keeps ordinary input as one native text span',
      (tester) async {
    final controller = EmojiEditingController(text: '普通中文 plain text');
    addTearDown(controller.dispose);

    await tester.pumpWidget(CupertinoApp(
      home: WeChatComposer(
        controller: controller,
        onMore: () {},
        onVoice: () {},
        onEmoji: () {},
        onSend: () {},
      ),
    ));

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    final span = editable.controller.buildTextSpan(
      context: tester.element(find.byType(EditableText)),
      withComposing: true,
    );
    expect(span.toPlainText(), '普通中文 plain text');
    expect(span.text, '普通中文 plain text');
    expect(span.children, isNull);
  });

  testWidgets('输入框控制器把目录内 emoji 渲染为彩色字形（与气泡一致）', (tester) async {
    final controller = EmojiEditingController(text: 'a🥲b');
    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: WeChatComposer(
            controller: controller,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 🥲 在动态目录中：输入框内出现与气泡相同的动态字形覆盖层。
    expect(find.byType(EmojiAnimatedGlyph), findsOneWidget);
    // 文本内容保持不变：光标/选区/发送路径仍操作原始字符串。
    expect(controller.text, 'a🥲b');
  });

  testWidgets('输入 emoji 覆盖层在文本缩放改变时无需输入也会重排', (tester) async {
    final controller = EmojiEditingController(text: '🥲a');
    addTearDown(controller.dispose);
    Widget app(TextScaler scaler) => CupertinoApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: scaler),
            child: WeChatComposer(
              controller: controller,
              onMore: () {},
              onVoice: () {},
              onEmoji: () {},
              onSend: () {},
            ),
          ),
        );

    await tester.pumpWidget(app(const TextScaler.linear(2)));
    await tester.pump();
    expect(
      tester.widget<EmojiAnimatedGlyph>(find.byType(EmojiAnimatedGlyph)).size,
      closeTo(17 * 1.18 * 2, 0.01),
    );

    await tester.pumpWidget(app(const TextScaler.linear(1)));
    await tester.pump();
    expect(
      tester.widget<EmojiAnimatedGlyph>(find.byType(EmojiAnimatedGlyph)).size,
      closeTo(17 * 1.18, 0.01),
    );
  });

  testWidgets('清空输入后不会保留 emoji 覆盖层', (tester) async {
    final controller = EmojiEditingController(text: '🥲');
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: WeChatComposer(
        controller: controller,
        onMore: () {},
        onVoice: () {},
        onEmoji: () {},
        onSend: () {},
      ),
    ));
    await tester.pump();
    expect(find.byType(EmojiAnimatedGlyph), findsOneWidget);
    controller.clear();
    await tester.pump();
    expect(find.byType(EmojiAnimatedGlyph), findsNothing);
  });

  testWidgets(
      'bare emoji controller keeps native source text without WidgetSpan',
      (tester) async {
    final controller = EmojiEditingController(text: 'a🥲b');
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoTextField(controller: controller),
    ));
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(
      editable.controller
          .buildTextSpan(
            context: tester.element(find.byType(EditableText)),
            withComposing: true,
          )
          .toPlainText(),
      'a🥲b',
    );
    expect(find.byType(EmojiAnimatedGlyph), findsNothing);
  });

  testWidgets('controller replacement and unmount detach emoji overlay safely',
      (tester) async {
    final first = EmojiEditingController(text: '🥲');
    final second = EmojiEditingController(text: '🥲');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget app(TextEditingController controller) => CupertinoApp(
          home: WeChatComposer(
            controller: controller,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        );

    await tester.pumpWidget(app(first));
    await tester.pump();
    await tester.pumpWidget(app(second));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('maxLines input scroll repositions and clips emoji overlay',
      (tester) async {
    final controller = EmojiEditingController(
      text: List<String>.filled(8, '🥲').join('\n'),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 280,
        child: WeChatComposer(
          controller: controller,
          onMore: () {},
          onVoice: () {},
          onEmoji: () {},
          onSend: () {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('composer-input')));
    await tester.pump();
    final renderEditable = _renderEditableFor(tester);
    expect(renderEditable.offset.pixels, 0);
    expect(find.byKey(const ValueKey('emoji-input-glyph-0-0')), findsOneWidget);
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: controller.text,
      selection: TextSelection.collapsed(offset: controller.text.length),
    ));
    await tester.pumpAndSettle();
    expect(renderEditable.offset.pixels, greaterThan(0));
    final inputRect = tester.getRect(find.byKey(const Key('composer-input')));
    for (final glyph in find.byType(EmojiAnimatedGlyph).evaluate()) {
      final glyphFinder =
          find.byElementPredicate((element) => identical(element, glyph));
      expect(inputRect.overlaps(tester.getRect(glyphFinder)), isTrue);
    }
    expect(find.byKey(const ValueKey('emoji-input-glyph-0-0')), findsNothing);
  });

  testWidgets('真实 EditableText 保持多 emoji 的 UTF-16 选区并在中间替换', (tester) async {
    final controller = EmojiEditingController(text: '🥲🥲中文x');
    addTearDown(controller.dispose);

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: WeChatComposer(
            controller: controller,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('composer-input')));
    await tester.pump();

    // 这是实际挂载在 EditableText 上的 span；它必须与 TextInput 的 UTF-16
    // 模型逐码元一致，不能以 U+FFFC placeholder 压缩动态 emoji。
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(
      editable.controller
          .buildTextSpan(
            context: tester.element(find.byType(EditableText)),
            withComposing: true,
          )
          .toPlainText(),
      controller.text,
    );

    // 两个 emoji 占 4 个 UTF-16 码元。用户先把光标点到两个 emoji 的末尾，
    // 再由真实 TextInput 通道提交插入，不能落到 WidgetSpan 的 placeholder 偏移。
    final renderEditable = _renderEditableFor(tester);
    await tester.tapAt(renderEditable.localToGlobal(
      renderEditable.getLocalRectForCaret(const TextPosition(offset: 4)).center,
    ));
    await tester.pump();
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '🥲🥲Z中文x',
      selection: TextSelection.collapsed(offset: 5),
    ));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '🥲🥲Zokx',
      selection: TextSelection.collapsed(offset: 7),
    ));
    await tester.pump();

    expect(controller.text, '🥲🥲Zokx');
    expect(controller.selection, const TextSelection.collapsed(offset: 7));
    expect(find.byType(EmojiAnimatedGlyph), findsNWidgets(2));
  });

  testWidgets('多行 ZWJ 文本保留原始 composing 与 UTF-16 span', (tester) async {
    const family = '👨‍👩‍👧‍👦';
    final controller = EmojiEditingController(text: '🥲\n中文$family');
    addTearDown(controller.dispose);
    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: WeChatComposer(
          controller: controller,
          onMore: () {},
          onVoice: () {},
          onEmoji: () {},
          onSend: () {},
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('composer-input')));
    await tester.pump();
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '🥲\n中文👨‍👩‍👧‍👦',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 3, end: 5),
    ));
    await tester.pump();

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(
      editable.controller
          .buildTextSpan(
            context: tester.element(find.byType(EditableText)),
            withComposing: true,
          )
          .toPlainText(),
      controller.text,
    );
    expect(controller.value.composing, const TextRange(start: 3, end: 5));
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
        child:
            Center(child: QuoteReturnBannerButton(onTap: () => tapped = true)),
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

  test('控制器不重写平台 IME 的 composing 或 UTF-16 selection', () {
    final controller = EmojiEditingController(text: '🥲ni');
    controller.value = const TextEditingValue(
      text: '🥲ni',
      selection: TextSelection.collapsed(offset: 1),
      composing: TextRange(start: 1, end: 3),
    );
    expect(controller.selection, const TextSelection.collapsed(offset: 1));
    expect(controller.value.composing, const TextRange(start: 1, end: 3));
  });
}
