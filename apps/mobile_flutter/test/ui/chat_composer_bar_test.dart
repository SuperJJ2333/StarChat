import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_bar.dart';
import 'package:liuhetong_mobile/ui/chat/chat_composer_state.dart';

void main() {
  test('send is visible whenever the composer has text including emoji', () {
    expect(
      const ChatComposerState(
        focused: false,
        hasText: true,
        panel: ComposerPanel.none,
      ).showsSend,
      isTrue,
    );
    expect(
      const ChatComposerState(
        focused: true,
        hasText: true,
        panel: ComposerPanel.none,
      ).showsSend,
      isTrue,
    );
  });

  testWidgets('composer keeps voice input emoji trailing DOM order',
      (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 393,
              child: ChatComposerBar(
                controller: controller,
                focusNode: focusNode,
                onMore: () {},
                onVoice: () {},
                onEmoji: () {},
                onSend: () {},
              ),
            ),
          ),
        ),
      ),
    );

    final voice = find.byKey(const Key('composer-voice'));
    final input = find.byKey(const Key('composer-input'));
    final emoji = find.byKey(const Key('composer-emoji'));
    final more = find.byKey(const Key('composer-more'));
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(find.byKey(const Key('composer-send')), findsNothing);
    expect(tester.getTopLeft(voice).dx, lessThan(tester.getTopLeft(input).dx));
    expect(tester.getTopLeft(input).dx, lessThan(tester.getTopLeft(emoji).dx));
    expect(tester.getTopLeft(emoji).dx, lessThan(tester.getTopLeft(more).dx));
    for (final finder in [voice, emoji, more]) {
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    expect(tester.getSize(input).height, greaterThanOrEqualTo(40));
  });

  testWidgets('focused text replaces more with send', (tester) async {
    final controller = TextEditingController();
    final focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatComposerBar(
            controller: controller,
            focusNode: focusNode,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    );
    focusNode.requestFocus();
    controller.text = '明天见';
    await tester.pump();

    expect(find.byKey(const Key('composer-more')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('composer-send'))),
      const Size.square(44),
    );
    final surface = tester.widget<DecoratedBox>(
      find.byKey(const Key('composer-send-surface')),
    );
    expect(
      (surface.decoration as BoxDecoration).color,
      const Color(0xFF06AD56),
    );
  });

  testWidgets('emoji without focus replaces more with pressed send',
      (tester) async {
    final controller = TextEditingController(text: '😀');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatComposerBar(
            controller: controller,
            onMore: () {},
            onVoice: () {},
            onEmoji: () {},
            onSend: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('composer-more')), findsNothing);
    expect(find.byKey(const Key('composer-send')), findsOneWidget);
    expect(find.byKey(const Key('composer-send-surface')), findsOneWidget);
  });
}
