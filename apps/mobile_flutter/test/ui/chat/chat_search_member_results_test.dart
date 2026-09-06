import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/member_directory_service.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

ChatSearchMessage message({String sender = '@a:x', String? summary}) =>
    ChatSearchMessage(
      eventId: 'event',
      senderId: sender,
      senderDisplayName: '历史昵称',
      timestamp: DateTime(2026, 9, 6),
      timelineOrder: 1,
      visibleText: 'Hello 原始正文',
      displayText: summary,
    );

void main() {
  testWidgets('member-only results show full body and the real sender avatar',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: true,
      memberEntries: const [
        MemberDirectoryEntry(userId: '@a:x', remark: '好友备注')
      ],
      memberAvatarBuilder: (_, member) => Text('头像:${member.userId}'),
      search: (filters, {cursor, limit = 50}) async => [message()],
      onJumpToMessage: (_) {},
    )));
    await tester.tap(find.byKey(const Key('chat-search-filter-member')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('member-picker-@a:x')));
    await tester.pumpAndSettle();
    expect(find.text('Hello 原始正文', findRichText: true), findsOneWidget);
    expect(find.text('头像:@a:x'), findsOneWidget);
    expect(find.text('好友备注'), findsOneWidget);
  });

  testWidgets('departed sender still resolves avatar and media summary',
      (tester) async {
    MemberDirectoryEntry? resolved;
    await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
      isGroup: true,
      memberEntries: const [],
      memberAvatarBuilder: (_, member) {
        resolved = member;
        return const Icon(CupertinoIcons.person_fill,
            key: Key('sender-avatar'));
      },
      search: (filters, {cursor, limit = 50}) async =>
          [message(sender: '@left:x', summary: '[语音消息]')],
      onJumpToMessage: (_) {},
    )));
    await tester.enterText(find.byKey(const Key('chat-search-input')), 'hello');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('[语音消息]', findRichText: true), findsOneWidget);
    expect(find.byKey(const Key('sender-avatar')), findsOneWidget);
    expect(resolved?.userId, '@left:x');
    expect(resolved?.displayName, '历史昵称');
  });

  test('display labels do not widen body-only case-insensitive matching', () {
    final media = message(summary: '[图片消息]');
    expect(ChatSearchFilters(keyword: 'hello').matches(media), isTrue);
    expect(ChatSearchFilters(keyword: '图片消息').matches(media), isFalse);
    final segments = buildHighlightSnippet(message().visibleText, 'hello');
    expect(segments.where((s) => s.highlighted).single.text, 'Hello');
  });
}
