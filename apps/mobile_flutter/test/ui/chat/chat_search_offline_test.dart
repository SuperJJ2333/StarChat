import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

/// 微信级加载模型（2026-09-19 审计）：聊天记录搜索原先在加载中显示整页 spinner、
/// 失败显示整页「查询失败」，把**已经拿到的结果**顶掉（`_lastPage` 渲染分支不可达）。
/// 新契约：已有结果时永远先渲染结果，加载/失败降级为内联状态条。
ChatSearchMessage _message(String id, String text) => ChatSearchMessage(
      eventId: id,
      senderId: '@a:example',
      senderDisplayName: 'A',
      timestamp: DateTime.utc(2026, 9, 19, 8),
      timelineOrder: 1,
      visibleText: text,
    );

void main() {
  testWidgets('已有结果时：再次查询不显示整页 spinner，失败也保留结果并给出内联重试',
      (tester) async {
    final calls = <Completer<List<ChatSearchMessage>>>[];
    Future<List<ChatSearchMessage>> search(ChatSearchFilters filters,
        {ChatSearchCursor? cursor, int limit = 50}) {
      final completer = Completer<List<ChatSearchMessage>>();
      calls.add(completer);
      return completer.future;
    }

    await tester.pumpWidget(CupertinoApp(
      home: ChatSearchPage(
        isGroup: false,
        search: search,
        memberEntries: const [],
        onJumpToMessage: (_) {},
      ),
    ));

    await tester.enterText(
        find.byKey(const Key('chat-search-input')), 'hello');
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, hasLength(1));
    calls.first.complete([_message(r'$1', 'hello world')]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-search-results')), findsOneWidget);

    // 第二次查询在飞：结果必须留在屏幕上（旧实现换成整页 loading）。
    await tester.enterText(
        find.byKey(const Key('chat-search-input')), 'hello2');
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls.length, greaterThanOrEqualTo(2));
    expect(find.byKey(const Key('chat-search-results')), findsOneWidget,
        reason: '已有结果时不得用整页 spinner 顶掉');
    expect(find.byType(CupertinoActivityIndicator), findsNothing,
        reason: '加载中只允许内联提示，不允许整页加载圈');

    // 第二次查询失败：结果仍在，并出现内联重试（而不是整页「查询失败」）。
    calls.last.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-search-results')), findsOneWidget,
        reason: '刷新失败不得清空或替换已渲染结果');
    expect(find.byKey(const Key('chat-search-retry')), findsOneWidget);
  });
}
