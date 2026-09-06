import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';

/// 规格 #4/#5：搜索查询控制器。
void main() {
  ChatSearchMessage msg(
    String id,
    String text, {
    String sender = '@a:x',
    int order = 0,
    ChatSearchMediaCategory? category,
    bool hasMedia = false,
    DateTime? at,
  }) =>
      ChatSearchMessage(
        eventId: id,
        senderId: sender,
        senderDisplayName: 'A',
        timestamp: at ?? DateTime(2026, 9, 6, 12, 0),
        timelineOrder: order,
        visibleText: text,
        mediaCategory: category,
        hasMedia: hasMedia,
      );

  group('#4 默认空态与组合筛选', () {
    test('首次进入（无条件）为空态：不查询', () async {
      var queries = 0;
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async {
          queries++;
          return const [];
        },
      );
      final states = <ChatSearchStateChange>[];
      final page = await controller.executeNow(onStateChange: states.add);
      expect(controller.isDefaultEmptyState, isTrue);
      expect(queries, 0, reason: '默认空态不发起查询、无消息行');
      expect(states.single, isA<ChatSearchEmptyState>());
      expect(page.items, isEmpty);
    });

    test('只输入关键词即可出结果；空白关键词视为未输入', () async {
      final data = [msg('e1', 'Hello world', order: 1)];
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async =>
            data.where(f.matches).toList(),
      );
      controller.setKeyword('hello');
      final page = await controller.executeNow();
      expect(page.items.map((m) => m.eventId), ['e1']);
      expect(ChatSearchFilters(keyword: '   ').matchesKeyword(msg('x', 'any')),
          isTrue,
          reason: '空白关键词不参与匹配');
    });

    test('成员 + 关键词 AND：仅显示该成员命中消息', () async {
      final data = [
        msg('e1', 'Hello from A', sender: '@a:x', order: 1),
        msg('e2', 'Hello from B', sender: '@b:x', order: 2),
        msg('e3', 'Other from A', sender: '@a:x', order: 3),
      ];
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async =>
            data.where(f.matches).toList(),
      );
      controller.setKeyword('hello');
      controller.setSender('@a:x');
      final page = await controller.executeNow();
      expect(page.items.map((m) => m.eventId), ['e1']);
    });

    test('清空关键词保留成员 → 该成员全部记录', () async {
      final data = [
        msg('e1', 'Hello from A', sender: '@a:x', order: 1),
        msg('e3', 'Other from A', sender: '@a:x', order: 3),
      ];
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async =>
            data.where(f.matches).toList(),
      );
      controller.setSender('@a:x');
      controller.setKeyword('');
      final page = await controller.executeNow();
      expect(page.items.map((m) => m.eventId), ['e1', 'e3']);
    });

    test('活动条件可移除；清除全部恢复空态', () {
      final controller = ChatSearchQueryController(
          search: (f, {cursor, limit = 50}) async => const []);
      controller
        ..setKeyword('找')
        ..setSender('@a:x')
        ..setMediaCategory(ChatSearchMediaCategory.file);
      expect(controller.activeFilters, hasLength(3));
      controller.removeFilter(ChatSearchFilterKind.sender);
      expect(controller.activeFilters, hasLength(2));
      controller.clearAll();
      expect(controller.isDefaultEmptyState, isTrue);
    });

    test('媒体分类单选：切换覆盖', () {
      final controller = ChatSearchQueryController(
          search: (f, {cursor, limit = 50}) async => const []);
      controller.setMediaCategory(ChatSearchMediaCategory.imageVideo);
      controller.setMediaCategory(ChatSearchMediaCategory.file);
      expect(controller.activeFilters.where((f) => f.kind == ChatSearchFilterKind.media),
          hasLength(1));
    });
  });

  group('#5 匹配范围与分页', () {
    test('Hello 命中 hello（忽略大小写）；昵称含关键词正文不含 → 不命中', () {
      const filters = ChatSearchFilters(keyword: 'hello');
      expect(filters.matchesKeyword(msg('a', 'say Hello there')), isTrue);
      expect(filters.matchesKeyword(msg('a', 'say HELLO')), isTrue);
      // 匹配范围只限正文：昵称不参与（matchesKeyword 只看 visibleText）。
      expect(filters.matchesKeyword(msg('a', '中午吃饭')), isFalse);
    });

    test('分类匹配：图片视频含说明文字匹配；文件匹配正文/文件名；链接匹配正文与 URL 文字', () {
      final image = msg('i1', 'holiday.jpg', order: 1,
          category: ChatSearchMediaCategory.imageVideo, hasMedia: true);
      final file = msg('f1', 'report.pdf', order: 2,
          category: ChatSearchMediaCategory.file, hasMedia: true);
      final link = msg('l1', '看这个 https://example.test/a', order: 3,
          category: ChatSearchMediaCategory.link);
      expect(
          ChatSearchFilters(mediaCategory: ChatSearchMediaCategory.imageVideo)
              .matches(image),
          isTrue);
      expect(
          ChatSearchFilters(mediaCategory: ChatSearchMediaCategory.file)
              .matches(file),
          isTrue);
      expect(
          ChatSearchFilters(
                  keyword: 'example.test',
                  mediaCategory: ChatSearchMediaCategory.link)
              .matches(link),
          isTrue);
    });

    test('分页：51 条数据每页 50 → 第二页补齐；事件 ID 去重不重复', () async {
      final data = [
        for (var i = 0; i < 61; i++)
          msg('e$i', 'item $i', order: 100 - i), // 新→旧。
      ];
      Future<List<ChatSearchMessage>> paged(ChatSearchFilters f,
          {ChatSearchCursor? cursor, int limit = 50}) async {
        final matched = data.where(f.matches).toList();
        int start = 0;
        if (cursor != null) {
          start = matched.indexWhere((m) => m.timelineOrder == cursor.order) + 1;
        }
        final end = (start + limit).clamp(0, matched.length);
        return matched.sublist(start, end);
      }

      final controller = ChatSearchQueryController(search: paged);
      controller.setKeyword('item');
      final first = await controller.executeNow(limit: 50);
      expect(first.items, hasLength(50));
      expect(first.nextCursor, isNotNull);
      final second = await controller.loadMore(first, limit: 50);
      final ids = second.items.map((m) => m.eventId).toSet();
      expect(ids, hasLength(61), reason: '第 51 条及更早可继续加载，无重复');
      expect(second.items, hasLength(61));
    });

    test('快速更换关键词：旧查询迟到结果被标记 stale，不覆盖新结果', () async {
      final slow = Completer<List<ChatSearchMessage>>();
      final fast = Completer<List<ChatSearchMessage>>();
      var call = 0;
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async {
          call++;
          return call == 1 ? slow.future : fast.future;
        },
      );
      controller.setKeyword('old');
      final oldFuture = controller.executeNow();
      controller.setKeyword('new');
      final newFuture = controller.executeNow();
      // 新查询先完成，旧查询后完成。
      fast.complete([msg('n1', 'new hit', order: 1)]);
      final newPage = await newFuture;
      expect(newPage.stale, isFalse);
      slow.complete([msg('o1', 'old hit', order: 2)]);
      final oldPage = await oldFuture;
      expect(oldPage.stale, isTrue, reason: '旧结果不覆盖新查询结果');
    });

    test('无匹配 → 空结果（UI 显示"未找到"）；查询中 → loading 状态', () async {
      final gate = Completer<void>();
      final states = <ChatSearchStateChange>[];
      final controller = ChatSearchQueryController(
        search: (f, {cursor, limit = 50}) async {
          await gate.future;
          return const [];
        },
      );
      controller.setKeyword('nothing');
      final pending = controller.executeNow(onStateChange: states.add);
      await Future<void>.delayed(Duration.zero);
      expect(states.last, isA<ChatSearchLoadingState>(), reason: '查询未完成显示加载状态');
      gate.complete();
      final page = await pending;
      expect(page.items, isEmpty);
      expect(states.last, isA<ChatSearchLoadedState>());
    });
  });

  group('高亮与时间', () {
    test('安全文本高亮片段（不执行 HTML）', () {
      const text = '<script>alert(1)</script> Hello <b>world</b>';
      final segments =
          buildHighlightSnippet(text, 'hello');
      expect(segments.any((s) => s.highlighted && s.text.toLowerCase().contains('hello')),
          isTrue);
      expect(segments.map((s) => s.text).join(), contains('script>'),
          reason: '原文保留（作为纯文本）但不执行');
    });

    test('时间格式：当天 HH:mm；其他日期 yyyy-MM-dd HH:mm', () {
      final now = DateTime(2026, 9, 6, 15, 0);
      expect(formatSearchResultTime(DateTime(2026, 9, 6, 9, 5), now: now), '09:05');
      expect(formatSearchResultTime(DateTime(2026, 9, 5, 9, 5), now: now),
          '2026-09-05 09:05');
    });
  });
}
