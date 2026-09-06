import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/ui/chat/chat_forward_picker_page.dart';

ChatForwardCandidate _candidate(String id, String title,
        {bool isGroup = false, int memberCount = 0}) =>
    ChatForwardCandidate(
      roomId: id,
      title: title,
      avatar: const ColoredBox(color: CupertinoColors.systemGrey),
      isGroup: isGroup,
      memberCount: memberCount,
    );

void main() {
  testWidgets('confirmation disables duplicate sends while request is pending',
      (tester) async {
    final pending = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatForwardPickerPage(
      candidates: [_candidate('a', '群聊')],
      recentRoomIds: const [],
      onForward: (_) {
        attempts++;
        return pending.future;
      },
    )));
    await tester.tap(find.byKey(const Key('forward-chat-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forward-confirm-send')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('forward-confirm-send')));
    await tester.pump();
    expect(attempts, 1);
    expect(
        tester
            .widget<CupertinoButton>(find.widgetWithText(CupertinoButton, '取消'))
            .onPressed,
        isNull);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('forward-confirmation-sheet')), findsOneWidget);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forward-confirmation-sheet')), findsNothing);
  });

  testWidgets('bottom card previews content and cancel never sends',
      (tester) async {
    var sends = 0;
    final candidates = List<ChatForwardCandidate>.unmodifiable([
      _candidate('z', 'Z群'),
      _candidate('a', 'A群'),
    ]);
    await tester.pumpWidget(CupertinoApp(
        home: ChatForwardPickerPage(
      candidates: candidates,
      recentRoomIds: const [],
      contentPreview: '本次转发的内容',
      onForward: (_) async {
        sends++;
      },
    )));
    expect(tester.getTopLeft(find.text('Z群')).dy,
        lessThan(tester.getTopLeft(find.text('A群')).dy));
    final row = find.byKey(const Key('forward-chat-z'));
    expect(find.descendant(of: row, matching: find.byType(CupertinoButton)),
        findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final fades = tester.widgetList<FadeTransition>(
        find.descendant(of: row, matching: find.byType(FadeTransition)));
    expect(fades.any((fade) => fade.opacity.value < 1), isTrue);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(find.text('本次转发的内容'), findsOneWidget);
    final sheet = find.byKey(const Key('forward-confirmation-sheet'));
    expect(tester.getBottomRight(sheet).dy, 600);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(sheet, findsNothing);
    expect(find.text('选择聊天'), findsOneWidget);
  });

  testWidgets('recent selection respects multi mode and send errors can retry',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatForwardPickerPage(
      candidates: [_candidate('a', '项目群')],
      recentRoomIds: const ['a'],
      onForward: (_) async {
        if (++attempts == 1) throw StateError('failed');
      },
    )));
    await tester.tap(find.text('多选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forward-recent-a')));
    await tester.pumpAndSettle();
    expect(find.text('发送(1)'), findsOneWidget);
    expect(find.byKey(const Key('forward-confirmation-sheet')), findsNothing);
    await tester.tap(find.text('发送(1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('转发失败，请重试'), findsOneWidget);
    expect(attempts, 1);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });

  testWidgets('renders search, recent forwards and recent chat list',
      (tester) async {
    var forwarded = <String>[];
    await tester.pumpWidget(CupertinoApp(
      home: ChatForwardPickerPage(
        candidates: [
          _candidate('room-current', '当前会话'),
          _candidate('room-a', '项目交流群', isGroup: true, memberCount: 5),
          _candidate('room-b', '梁睿小丑'),
        ],
        recentRoomIds: const ['room-a'],
        onForward: (roomIds) async => forwarded.addAll(roomIds),
      ),
    ));
    await tester.pump();

    expect(find.text('选择聊天'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
    expect(find.byKey(const Key('forward-picker-search')), findsOneWidget);
    expect(find.text('最近转发'), findsOneWidget);
    expect(find.text('最近聊天'), findsOneWidget);
    expect(find.byKey(const Key('forward-recent-room-a')), findsOneWidget,
        reason: '最近转发横排展示最近转发的会话');
    expect(find.byKey(const Key('forward-chat-room-current')), findsOneWidget);
    expect(find.byKey(const Key('forward-chat-room-a')), findsOneWidget);
    expect(find.byKey(const Key('forward-chat-room-b')), findsOneWidget);

    await tester.tap(find.byKey(const Key('forward-chat-room-b')));
    await tester.pump();
    expect(forwarded, isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('发送给：'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(forwarded, ['room-b']);
  });

  testWidgets('multi-select toggles rows and batch-forwards once',
      (tester) async {
    var forwarded = <String>[];
    await tester.pumpWidget(CupertinoApp(
      home: ChatForwardPickerPage(
        candidates: [
          _candidate('room-a', '项目交流群'),
          _candidate('room-b', '梁睿小丑'),
        ],
        recentRoomIds: const [],
        onForward: (roomIds) async => forwarded.addAll(roomIds),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('多选'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('forward-chat-room-a')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('forward-chat-room-b')));
    await tester.pump();
    await tester.tap(find.text('发送(2)'));
    await tester.pump();

    expect(forwarded, isEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(forwarded, ['room-a', 'room-b']);
  });

  testWidgets('search filters the chat list by title', (tester) async {
    await tester.pumpWidget(CupertinoApp(
      home: ChatForwardPickerPage(
        candidates: [
          _candidate('room-a', '项目交流群'),
          _candidate('room-b', '梁睿小丑'),
        ],
        recentRoomIds: const [],
        onForward: (_) async {},
      ),
    ));
    await tester.pump();

    await tester.enterText(
        find.byKey(const Key('forward-picker-search')), '梁睿');
    await tester.pump();

    expect(find.text('梁睿小丑'), findsOneWidget);
    expect(find.text('项目交流群'), findsNothing);
  });
}
