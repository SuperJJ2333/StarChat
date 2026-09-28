import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

void main() {
  testWidgets('new query auto-paginates while old pagination is pending',
      (tester) async {
    final oldPage = Completer<ChatSearchSlice>();
    final calls = <String>[];
    ChatSearchMessage msg(String id) => ChatSearchMessage(
        eventId: id,
        senderId: 'a',
        senderDisplayName: 'A',
        timestamp: DateTime(2026),
        timelineOrder: 1,
        visibleText: id);
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: true,
      memberEntries: const [],
      onJumpToMessage: (_) {},
      search: (_, {cursor, limit = 50}) async => [],
      searchBatch: (f, {cursor, limit = 50}) async {
        calls.add('${f.keyword}:${cursor == null ? 'first' : 'next'}');
        if (cursor != null && f.keyword == 'old') return oldPage.future;
        return ChatSearchSlice(
            items: [msg('${f.keyword}-${cursor == null ? 'first' : 'last'}')],
            nextCursor: cursor == null
                ? ChatSearchCursor(order: 1, eventId: '${f.keyword}-cursor')
                : null);
      },
    )));
    final input = find.byKey(const Key('chat-search-input'));
    await tester.enterText(input, 'old');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(calls, contains('old:next'));
    await tester.enterText(input, 'new');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(calls, contains('new:next'));
    expect(find.text('new-last'), findsOneWidget);
    oldPage
        .complete(ChatSearchSlice(items: [msg('stale-old')], nextCursor: null));
    await tester.pumpAndSettle();
    expect(find.text('new-last'), findsOneWidget);
    expect(find.text('stale-old'), findsNothing);
    expect(find.byKey(const Key('chat-search-load-more')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
