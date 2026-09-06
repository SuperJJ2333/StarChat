import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/member_directory_service.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

void main() {
  testWidgets('member picker shows real avatar and authoritative remark',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
            isGroup: true,
            search: (f, {cursor, limit = 50}) async => [],
            memberEntries: const [
              MemberDirectoryEntry(
                  userId: '@a:x',
                  remark: 'Friend',
                  nickname: 'Nickname',
                  username: 'account')
            ],
            memberAvatarBuilder: (c, m) => const Icon(
                CupertinoIcons.person_crop_square,
                key: Key('real-avatar')),
            onJumpToMessage: (_) {})));
    await tester.tap(find.byKey(const Key('chat-search-filter-member')));
    await tester.pumpAndSettle();
    expect(find.text('Friend'), findsOneWidget);
    expect(find.text('Nickname'), findsNothing);
    expect(find.byKey(const Key('real-avatar')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('member-picker-search')), 'account');
    await tester.pumpAndSettle();
    expect(find.text('Friend'), findsOneWidget);
  });
  testWidgets('media date grid preserves AND filters and opens real previews',
      (tester) async {
    String? opened;
    final queries = <ChatSearchFilters>[];
    final messages = [
      for (final video in [false, true])
        ChatSearchMessage(
            eventId: video ? 'video' : 'image',
            senderId: '@a:x',
            senderDisplayName: 'Hidden sender',
            timestamp: DateTime(2026, 9, video ? 5 : 6),
            timelineOrder: video ? 1 : 2,
            visibleText: 'trip',
            mediaCategory: ChatSearchMediaCategory.imageVideo,
            hasMedia: true,
            isVideo: video,
            duration: video ? const Duration(seconds: 65) : null)
    ];
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
            isGroup: true,
            search: (f, {cursor, limit = 50}) async {
              queries.add(f);
              return messages.where(f.matches).toList();
            },
            memberEntries: const [
              MemberDirectoryEntry(userId: '@a:x', remark: 'Friend')
            ],
            mediaThumbnailBuilder: (c, m) => ColoredBox(
                key: Key('real-thumbnail-${m.eventId}'),
                color: CupertinoColors.systemBlue),
            onOpenMedia: (id) => opened = id,
            onJumpToMessage: (_) => fail('must preview'))));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'trip');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-search-filter-member')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('member-picker-@a:x')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-search-filter-media')));
    await tester.pumpAndSettle();
    expect(queries.last.keyword, 'trip');
    expect(queries.last.senderUserId, '@a:x');
    expect(queries.last.mediaCategory, ChatSearchMediaCategory.imageVideo);
    expect(find.text('Hidden sender'), findsNothing);
    expect(find.text('2026-9-6'), findsOneWidget);
    expect(find.text('2026-9-5'), findsOneWidget);
    expect(find.byKey(const Key('real-thumbnail-image')), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.play_fill), findsOneWidget);
    expect(find.text('1:05'), findsOneWidget);
    await tester.tap(find.byKey(const Key('category-media-video')));
    expect(opened, 'video');
    await tester.tap(find.byKey(const Key('category-media-image')));
    expect(opened, 'image');
  });
  testWidgets(
      'media grid appends the next page without losing earlier thumbnails',
      (tester) async {
    final messages = List.generate(
        51,
        (i) => ChatSearchMessage(
            eventId: 'media-$i',
            senderId: '@a:x',
            senderDisplayName: 'Sender',
            timestamp: DateTime(2026, 9, 6),
            timelineOrder: 51 - i,
            visibleText: '',
            mediaCategory: ChatSearchMediaCategory.imageVideo,
            hasMedia: true));
    var calls = 0;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: false,
      memberEntries: const [],
      onJumpToMessage: (_) {},
      search: (filters, {cursor, limit = 50}) async {
        calls++;
        return messages
            .where((m) => cursor == null || m.timelineOrder < cursor.order)
            .take(limit)
            .toList();
      },
    )));
    await tester.tap(find.byKey(const Key('chat-search-filter-media')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-media-media-0')), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('category-media-media-50')), 450,
        scrollable: find.descendant(
            of: find.byKey(const Key('chat-search-media-grid')),
            matching: find.byType(Scrollable)),
        maxScrolls: 40);
    await tester.pumpAndSettle();
    expect(
        calls, 3); // Initial page, final item, then empty end-of-history page.
    expect(find.byKey(const Key('category-media-media-50')), findsOneWidget);
    expect(find.byKey(const Key('chat-search-load-more')), findsNothing);
    final scrollable = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('chat-search-media-grid')),
        matching: find.byType(Scrollable)));
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-media-media-0')), findsOneWidget);
  });
  testWidgets('date jump lets host unwind nested routes without extra pop',
      (tester) async {
    late BuildContext roomContext;
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                  child: const Text('Open room'),
                  onPressed: () => Navigator.of(context)
                      .push(CupertinoPageRoute(builder: (context) {
                    roomContext = context;
                    return const CupertinoPageScaffold(child: Text('Room'));
                  })),
                ))));
    await tester.tap(find.text('Open room'));
    await tester.pumpAndSettle();
    final roomRoute = ModalRoute.of(roomContext)!;
    Navigator.of(roomContext).push(CupertinoPageRoute(
        builder: (_) => ChatSearchPage(
              isGroup: false,
              search: (f, {cursor, limit = 50}) async => [],
              memberEntries: const [],
              onJumpToMessage: (_) {},
              datesWithMessages: {DateTime(2026, 9, 6)},
              earliestMonth: DateTime(2026, 9),
              latestMonth: DateTime(2026, 9),
              onJumpToDate: (_) => Navigator.of(roomContext)
                  .popUntil((route) => route == roomRoute),
            )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-search-filter-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('calendar-day-6')));
    await tester.pumpAndSettle();
    expect(find.text('Room'), findsOneWidget);
    expect(find.text('Open room'), findsNothing);
  });
}
