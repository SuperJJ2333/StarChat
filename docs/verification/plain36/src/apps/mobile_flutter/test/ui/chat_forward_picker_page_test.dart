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
    expect(forwarded, ['room-b'], reason: '点击会话行即转发');
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

    expect(forwarded, ['room-a', 'room-b'], reason: '多选批量转发按选择顺序');
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
