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
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      4,
    );
    await tester.tap(find.text('红包'));
    expect(selected, ChatMoreAction.redPacket);
  });
}
