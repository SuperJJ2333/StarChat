import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/wechat_composer.dart';

void main() {
  testWidgets('typing and IME selection do not rebuild composer chrome',
      (tester) async {
    final controller = TextEditingController(text: 'a');
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
    final send = tester.widget(find.byKey(const Key('composer-send')));
    const editing = TextEditingValue(
      text: 'ni',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 2),
    );
    controller.value = editing;
    await tester.pump();
    expect(controller.value, editing);
    expect(tester.widget(find.byKey(const Key('composer-send'))), same(send));
    expect(find.text('ni'), findsOneWidget);
    controller.clear();
    await tester.pump();
    expect(find.byKey(const Key('composer-send')), findsNothing);
    expect(find.byKey(const Key('composer-more')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
