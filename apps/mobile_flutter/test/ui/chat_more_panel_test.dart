import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_more_panel.dart';

void main() {
  testWidgets('direct chat more panel shows transfer with a four-column grid',
      (tester) async {
    ChatMoreAction? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatMorePanel(
            onSelected: (value) => selected = value,
            showTransfer: true,
          ),
        ),
      ),
    );

    for (final label in const ['图片', '拍摄', '语音通话', '视频通话', '红包', '转账', '文件']) {
      expect(find.text(label), findsOneWidget);
    }
    // 末位固定“工具”入口：展开可扩展工具面板。
    expect(find.text('工具'), findsOneWidget);
    expect(find.byKey(const Key('chat-more-tools')), findsOneWidget);
    expect(find.byType(Icon), findsNWidgets(8));
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);
    expect(delegate.mainAxisExtent, 82);
    await tester.tap(find.text('转账'));
    expect(selected, ChatMoreAction.transfer);
  });

  testWidgets('group chat more panel hides the transfer entry', (tester) async {
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatMorePanel(onSelected: (_) {}, showTransfer: false),
        ),
      ),
    );

    expect(find.text('转账'), findsNothing);
    expect(find.text('红包'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.byType(Icon), findsNWidgets(7));
  });

  testWidgets('tools entry opens the extensible tools panel', (tester) async {
    var toolsOpened = false;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatMorePanel(onSelected: (_) {}, onTools: () => toolsOpened = true),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('chat-more-tools')));
    expect(toolsOpened, isTrue, reason: '点击“工具”展开工具面板');
  });

  testWidgets('more panel does not overflow at 393px and 1.3x text scale',
      (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(393, 852),
          textScaler: TextScaler.linear(1.3),
        ),
        child: CupertinoApp(
          home: Align(
            alignment: Alignment.bottomCenter,
            child: ChatMorePanel(onSelected: (_) {}, showTransfer: true),
          ),
        ),
      ),
    );

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
        tester.getSize(find.byKey(const Key('chat-more-panel'))).height, 232);
  });
}
