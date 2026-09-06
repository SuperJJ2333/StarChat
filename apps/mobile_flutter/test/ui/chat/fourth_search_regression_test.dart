import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

void main() {
  testWidgets('new query can paginate while old pagination is pending',
      (tester) async {
    final oldPage = Completer<List<ChatSearchMessage>>();
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
      search: (f, {cursor, limit = 50}) async {
        if (cursor != null && f.keyword == 'old') return oldPage.future;
        return [msg(f.keyword ?? 'none')];
      },
    )));
    final input = find.byKey(const Key('chat-search-input'));
    await tester.enterText(input, 'old');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-search-load-more')));
    await tester.pump();
    await tester.enterText(input, 'new');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('chat-search-load-more')), findsOneWidget);
    oldPage.complete([]);
    await tester.pump();
    expect(find.byKey(const Key('chat-search-load-more')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
