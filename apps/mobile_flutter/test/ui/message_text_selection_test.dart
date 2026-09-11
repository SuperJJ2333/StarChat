import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/message_action.dart';
import 'package:liuhetong_mobile/ui/chat/emoji_text.dart';
import 'package:liuhetong_mobile/ui/chat/message_text_selection.dart';

void main() {
  testWidgets(
      'full menu remains actionable and pointer up swaps a multiline range to the four actions',
      (tester) async {
    final textKey = GlobalKey();
    late BuildContext roomContext;
    final actions = <(MessageAction, String?)>[];

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Builder(builder: (context) {
          roomContext = context;
          return Center(
            child: SizedBox(
              width: 180,
              child: KeyedSubtree(
                key: textKey,
                child: const EmojiText('第一行🥲中文\n第二行用于拖动选择'),
              ),
            ),
          );
        }),
      ),
    ));

    void show() => MessageTextSelectionSession.show(
          roomContext: roomContext,
          text: '第一行🥲中文\n第二行用于拖动选择',
          textKey: textKey,
          messageRect: const Rect.fromLTWH(90, 200, 180, 48),
          isOwn: false,
          fullActions: const {MessageAction.copy, MessageAction.reply},
          onAction: (action, selected) => actions.add((action, selected)),
          onDismissed: () {},
        );

    show();
    await tester.pump();
    expect(find.byKey(const Key('message-bubble-menu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('message-action-copy')));
    await tester.pump();
    expect(actions, [(MessageAction.copy, null)]);
    expect(MessageTextSelectionSession.active, isNull);

    show();
    await tester.pump();
    final handle = find.byKey(const Key('selection-handle-end'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    final textBox = textKey.currentContext!.findRenderObject() as RenderBox;
    await gesture.moveTo(textBox.localToGlobal(const Offset(4, 4)));
    await tester.pump();
    expect(find.byType(RawMagnifier), findsOneWidget);
    expect(find.byKey(const Key('message-bubble-menu')), findsNothing);

    await gesture.up();
    await tester.pump();
    expect(find.byType(RawMagnifier), findsNothing);
    expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
    expect(find.byKey(const Key('message-action-selectAll')), findsOneWidget);
    expect(find.byKey(const Key('message-action-reply')), findsOneWidget);
    expect(find.byKey(const Key('message-action-forward')), findsOneWidget);

    await tester.tap(find.byKey(const Key('message-action-selectAll')));
    await tester.pump();
    expect(MessageTextSelectionSession.active, isNotNull);
    expect(find.byKey(const Key('message-bubble-menu')), findsOneWidget);

    await tester.dragFrom(
      tester.getCenter(find.byKey(textKey)),
      const Offset(0, -36),
    );
    await tester.pump();
    expect(MessageTextSelectionSession.active, isNull,
        reason: 'scrolling selected text cancels the active overlay');

    show();
    await tester.pump();
    await tester.tapAt(const Offset(4, 500));
    await tester.pump();
    expect(MessageTextSelectionSession.active, isNull,
        reason: 'tapping blank overlay space cancels the active overlay');
  });

  testWidgets(
      'EmojiText routes both overlapping handle targets and emits exact partial actions',
      (tester) async {
    final textKey = GlobalKey();
    late BuildContext roomContext;
    final actions = <(MessageAction, String?)>[];
    const source = '甲🥲乙\n丙[微笑]丁';

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Builder(builder: (context) {
          roomContext = context;
          return Center(
            child: SizedBox(
              width: 180,
              child: KeyedSubtree(
                key: textKey,
                child: const EmojiText(source),
              ),
            ),
          );
        }),
      ),
    ));

    void show() => MessageTextSelectionSession.show(
          roomContext: roomContext,
          text: source,
          textKey: textKey,
          messageRect: const Rect.fromLTWH(90, 200, 180, 48),
          isOwn: false,
          fullActions: const {MessageAction.copy, MessageAction.reply},
          onAction: (action, selected) => actions.add((action, selected)),
          onDismissed: () {},
        );

    Future<void> selectFirstGraphemeFromEnd(MessageAction action) async {
      show();
      await tester.pump();
      final end = find.byKey(const Key('selection-handle-end'));
      final textBox = textKey.currentContext!.findRenderObject() as RenderBox;
      final gesture = await tester.startGesture(tester.getCenter(end));
      await gesture.moveTo(textBox.localToGlobal(const Offset(0, 0)));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.tap(find.byKey(Key('message-action-${action.name}')));
      await tester.pump();
    }

    await selectFirstGraphemeFromEnd(MessageAction.copy);
    await selectFirstGraphemeFromEnd(MessageAction.reply);
    await selectFirstGraphemeFromEnd(MessageAction.forward);

    expect(actions, [
      (MessageAction.copy, '甲'),
      (MessageAction.reply, '甲'),
      (MessageAction.forward, '甲'),
    ]);

    show();
    await tester.pump();
    final end = find.byKey(const Key('selection-handle-end'));
    final cancelGesture = await tester.startGesture(tester.getCenter(end));
    await cancelGesture.moveBy(const Offset(-12, 0));
    await tester.pump();
    expect(find.byType(RawMagnifier), findsOneWidget);
    await cancelGesture.cancel();
    await tester.pump();
    expect(find.byType(RawMagnifier), findsNothing);
    expect(find.byKey(const Key('message-bubble-menu')), findsOneWidget);
  });

  testWidgets(
      'short EmojiText routes both 44px overlapping handles by nearest dot',
      (tester) async {
    final textKey = GlobalKey();
    late BuildContext roomContext;
    final actions = <String?>[];
    const source = '🥲乙';

    await tester.pumpWidget(CupertinoApp(
      home: CupertinoPageScaffold(
        child: Center(
          child: KeyedSubtree(
            key: textKey,
            child: const EmojiText(source),
          ),
        ),
      ),
    ));
    roomContext = textKey.currentContext!;

    void show() => MessageTextSelectionSession.show(
          roomContext: roomContext,
          text: source,
          textKey: textKey,
          messageRect: const Rect.fromLTWH(120, 280, 48, 24),
          isOwn: false,
          fullActions: const {MessageAction.copy},
          onAction: (_, selected) => actions.add(selected),
          onDismissed: () {},
        );

    Future<void> dragToOtherDot(Key from, Key to) async {
      final gesture =
          await tester.startGesture(tester.getCenter(find.byKey(from)));
      await gesture.moveBy(const Offset(0, 12));
      await gesture.moveTo(tester.getCenter(find.byKey(to)));
      await tester.pump();
      expect(find.byType(RawMagnifier), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(find.byKey(const Key('message-action-copy')), findsOneWidget);
      await tester.tap(find.byKey(const Key('message-action-copy')));
      await tester.pump();
    }

    show();
    await tester.pump();
    await dragToOtherDot(
      const Key('selection-handle-start'),
      const Key('selection-handle-end'),
    );

    show();
    await tester.pump();
    await dragToOtherDot(
      const Key('selection-handle-end'),
      const Key('selection-handle-start'),
    );

    expect(actions, ['乙', '🥲']);
  });
}
