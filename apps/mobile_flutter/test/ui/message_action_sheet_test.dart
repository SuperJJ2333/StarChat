import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_action.dart';
import 'package:liuhetong_mobile/ui/chat/message_action_sheet.dart';

void main() {
  testWidgets('sheet renders exactly the policy-provided actions',
      (tester) async {
    MessageAction? selected;
    await tester.pumpWidget(
      CupertinoApp(
        home: MessageActionSheet(
          actions: const {
            MessageAction.addToEmoji,
            MessageAction.deleteLocal,
            MessageAction.recall,
          },
          onSelected: (action) => selected = action,
        ),
      ),
    );

    expect(find.text('添加到表情'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('撤回'), findsOneWidget);
    expect(find.text('转发'), findsNothing);
    await tester.tap(find.text('删除'));
    expect(selected, MessageAction.deleteLocal);
  });

  testWidgets('multi-select bar exposes count, forward, delete and cancel',
      (tester) async {
    var forwarded = 0;
    var deleted = 0;
    var cancelled = 0;
    await tester.pumpWidget(
      CupertinoApp(
        home: MessageSelectionBar(
          count: 2,
          canForward: true,
          onForward: () => forwarded++,
          onDelete: () => deleted++,
          onCancel: () => cancelled++,
        ),
      ),
    );

    expect(find.text('已选择 2 条'), findsOneWidget);
    await tester.tap(find.byKey(const Key('selection-forward')));
    await tester.tap(find.byKey(const Key('selection-delete')));
    await tester.tap(find.byKey(const Key('selection-cancel')));
    expect((forwarded, deleted, cancelled), (1, 1, 1));
  });
}
