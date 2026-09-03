import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_more_panel.dart';

void main() {
  testWidgets('「工具」入口在传入 onTools 后可点击并触发回调', (tester) async {
    var toolsOpened = 0;
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 393,
        child: ChatMorePanel(
          onSelected: (_) {},
          onTools: () => toolsOpened++,
        ),
      ),
    ));

    expect(find.byKey(const Key('chat-more-tools')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-more-tools')));
    expect(toolsOpened, 1, reason: '传入 onTools 后点击「工具」应触发回调');
  });

  testWidgets('未传 onTools 时「工具」入口 onPressed 为 null（禁用态）', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: SizedBox(
        width: 393,
        child: ChatMorePanel(
          onSelected: (_) {},
          // onTools 缺失 → 复现当前 room_page 的实际接线缺陷
        ),
      ),
    ));

    final button = tester.widget<CupertinoButton>(
      find.byKey(const Key('chat-more-tools')),
    );
    expect(button.onPressed, isNull,
        reason: 'onTools 缺失导致工具入口被禁用，这就是“入口被屏蔽”的根因');
  });
}
