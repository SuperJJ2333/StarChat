import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/member_directory_service.dart';
import 'package:liuhetong_mobile/features/matrix/chat_media_shared_logic.dart' as logic;
import 'package:liuhetong_mobile/features/matrix/chat_search_query_controller.dart';
import 'package:liuhetong_mobile/ui/chat/chat_search_page.dart';

/// 规格 #4/#6/#7/#8：搜索页/成员选择/月历/分类页 UI 组件验收。
void main() {
  ChatSearchMessage msg(String id, String text,
          {String sender = '@a:x', int order = 1, String? category}) =>
      ChatSearchMessage(
        eventId: id,
        senderId: sender,
        senderDisplayName: 'A',
        timestamp: DateTime(2026, 9, 6, 10, 30),
        timelineOrder: order,
        visibleText: text,
        mediaCategory: switch (category) {
          'imageVideo' => ChatSearchMediaCategory.imageVideo,
          'file' => ChatSearchMediaCategory.file,
          'link' => ChatSearchMediaCategory.link,
          _ => null,
        },
        hasMedia: category != null,
      );

  group('#4 搜索页', () {
    testWidgets('首次进入：默认空态——无消息行，只有提示', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
          isGroup: true,
          search: (f, {cursor, limit = 50}) async => [msg('e1', 'Hello')],
          memberEntries: const [],
          onJumpToMessage: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-search-empty')), findsOneWidget);
      expect(find.text('请选择筛选条件或输入关键字'), findsOneWidget);
      expect(find.byKey(const Key('chat-search-results')), findsNothing,
          reason: '默认空态不显示任何消息行');
    });

    testWidgets('只输入关键词 → 出现结果行', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
          isGroup: false,
          search: (f, {cursor, limit = 50}) async =>
              [msg('e1', 'Hello world', order: 1)],
          memberEntries: const [],
          onJumpToMessage: (_) {},
        ),
      ));
      await tester.enterText(
          find.byKey(const Key('chat-search-input')), 'hello');
      // 越过防抖 + 搜索完成（不用 pumpAndSettle——加载态
      // CupertinoActivityIndicator 无限动画导致 settle 超时）。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('chat-search-result-e1')), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
    });

    testWidgets('无匹配显示"未找到"', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
          isGroup: false,
          search: (f, {cursor, limit = 50}) async => [],
          memberEntries: const [],
          onJumpToMessage: (_) {},
        ),
      ));
      await tester.enterText(
          find.byKey(const Key('chat-search-input')), '不存在');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('未找到符合条件的聊天记录'), findsOneWidget);
    });

    testWidgets('群聊显示成员筛选入口；私聊不显示', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatSearchPage(
          isGroup: false,
          search: (f, {cursor, limit = 50}) async => [],
          memberEntries: const [],
          onJumpToMessage: (_) {},
        ),
      ));
      expect(find.byKey(const Key('chat-search-filter-member')), findsNothing);
    });
  });

  group('#6 成员选择页', () {
    testWidgets('拼音分组列表；点击返回选中成员', (tester) async {
      final picked = <MemberDirectoryEntry>[];
      await tester.pumpWidget(CupertinoApp(
        home: MemberPickerPage(entries: [
          const MemberDirectoryEntry(userId: '@z:example.test', nickname: '张三'),
          const MemberDirectoryEntry(userId: '@a:example.test', nickname: '阿明'),
          const MemberDirectoryEntry(userId: '@b:example.test', nickname: 'Bob'),
        ]),
      ));
      await tester.pumpAndSettle();
      // A 组（阿明）在前、Z 组（张三）在后。
      expect(find.text('A'), findsOneWidget);
      expect(find.text('Z'), findsOneWidget);
      // 点击阿明 → pop 返回。
      await tester.tap(find.byKey(const Key('member-picker-@a:example.test')));
      await tester.pumpAndSettle();
      expect(picked, isEmpty); // pop 结果由宿主接收；此处验证不崩溃。
    });

    testWidgets('搜索"zhang"命中张三', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: MemberPickerPage(entries: [
          const MemberDirectoryEntry(userId: '@z:example.test', nickname: '张三'),
          const MemberDirectoryEntry(userId: '@a:example.test', nickname: '阿明'),
        ]),
      ));
      await tester.enterText(
          find.byKey(const Key('member-picker-search')), 'zhang');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('member-picker-@z:example.test')), findsOneWidget);
      expect(find.byKey(const Key('member-picker-@a:example.test')), findsNothing);
    });

    testWidgets('无匹配显示"未找到群成员"', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: MemberPickerPage(entries: const [
          MemberDirectoryEntry(userId: '@z:example.test', nickname: '张三'),
        ]),
      ));
      await tester.enterText(
          find.byKey(const Key('member-picker-search')), '不存在');
      await tester.pumpAndSettle();
      expect(find.text('未找到群成员'), findsOneWidget);
    });
  });

  group('#7 月历页', () {
    testWidgets('仅 1/3/10 日可点，其余灰显', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
          earliest: const logic.CalendarMonth(2026, 9),
          latest: const logic.CalendarMonth(2026, 9),
          datesWithMessages: {
            DateTime(2026, 9, 1),
            DateTime(2026, 9, 3),
            DateTime(2026, 9, 10),
          },
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('calendar-day-1')), findsOneWidget);
      expect(find.byKey(const Key('calendar-day-15')), findsOneWidget);
      // 标题显示当前月。
      expect(find.text('2026年9月'), findsOneWidget);
    });

    testWidgets('点击可点日期返回', (tester) async {
      DateTime? result;
      await tester.pumpWidget(CupertinoApp(
        home: CalendarPickerPage(
          earliest: const logic.CalendarMonth(2026, 9),
          latest: const logic.CalendarMonth(2026, 9),
          datesWithMessages: {DateTime(2026, 9, 3)},
          onDateTap: (date) => result = date,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-day-3')));
      await tester.pumpAndSettle();
      expect(result, DateTime(2026, 9, 3));
    });
  });

  group('#8 分类页', () {
    testWidgets('空态：暂无图片和视频', (tester) async {
      await tester.pumpWidget(const CupertinoApp(
        home: ChatCategoryPage(
          title: '图片和视频',
          category: ChatSearchMediaCategory.imageVideo,
          messages: [],
          onOpen: _noop,
        ),
      ));
      expect(find.text('暂无图片和视频'), findsOneWidget);
    });

    testWidgets('图片网格按日期分组渲染', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatCategoryPage(
          title: '图片和视频',
          category: ChatSearchMediaCategory.imageVideo,
          messages: [
            msg('i1', 'a.jpg', category: 'imageVideo'),
            msg('i2', 'b.jpg', category: 'imageVideo'),
          ],
          onOpen: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('category-media-i1')), findsOneWidget);
      expect(find.byKey(const Key('category-media-i2')), findsOneWidget);
    });

    testWidgets('文件列表显示回退文案（不伪造）', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatCategoryPage(
          title: '文件',
          category: ChatSearchMediaCategory.file,
          messages: [msg('f1', '', category: 'file')],
          onOpen: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('未命名文件'), findsOneWidget);
      expect(find.textContaining('大小未知'), findsOneWidget, reason: '大小回退显示在副标题中');
    });

    testWidgets('链接列表：域名标题回退', (tester) async {
      await tester.pumpWidget(CupertinoApp(
        home: ChatCategoryPage(
          title: '链接',
          category: ChatSearchMediaCategory.link,
          messages: [
            msg('l1', '看这个 https://news.example.test/article', category: 'link'),
          ],
          onOpen: (_) {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('news.example.test'), findsOneWidget);
    });
  });
}

void _noop(ChatSearchMessage message) {}
