import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_more_panel.dart';

void main() {
  testWidgets('more panel uses a four-column grid with six real icons',
      (tester) async {
    ChatMoreAction? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: SizedBox(
          width: 393,
          child: ChatMorePanel(onSelected: (value) => selected = value),
        ),
      ),
    );

    for (final label in const ['图片', '拍摄', '语音通话', '视频通话', '红包', '文件']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(Icon), findsNWidgets(6));
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 4);
    expect(delegate.mainAxisExtent, 82);
    await tester.tap(find.text('红包'));
    expect(selected, ChatMoreAction.redPacket);
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
            child: ChatMorePanel(onSelected: (_) {}),
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
