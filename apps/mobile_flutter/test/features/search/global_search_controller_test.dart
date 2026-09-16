import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_controller.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';

GlobalSearchMessageRecord _record(String id, String body,
        {String sender = '@peer:test',
        String senderName = '张三',
        DateTime? at}) =>
    GlobalSearchMessageRecord(
      eventId: id,
      senderId: sender,
      senderName: senderName,
      timestamp: at ?? DateTime.utc(2026, 9, 15, 10),
      body: body,
    );

GlobalSearchIndex _indexWith(Map<String, List<GlobalSearchMessageRecord>> rooms,
    {Map<String, bool>? groups}) {
  final index = GlobalSearchIndex();
  rooms.forEach((roomId, records) {
    index.recordRoom(
      roomId: roomId,
      roomName: roomId == '!group:test' ? '数智经济中心' : '张三',
      isGroup: groups?[roomId] ?? roomId.startsWith('!group'),
      messages: records,
    );
  });
  return index;
}

void main() {
  group('GlobalSearchIndex（device-side）', () {
    test('matches substring, case-insensitive, newest first', () {
      final index = _indexWith({
        '!group:test': [
          _record(r'$a', '项目文件已发送', at: DateTime.utc(2026, 9, 15, 9)),
          _record(r'$b', 'Project 计划', at: DateTime.utc(2026, 9, 15, 11)),
        ],
      });
      expect([for (final hit in index.search('项目')) hit.eventId],
          [r'$a']);
      expect([for (final hit in index.search('project')) hit.eventId],
          [r'$b'], reason: '英文忽略大小写');
      expect(index.search('   '), isEmpty, reason: '空查询不返回任何结果');
    });

    test('blank and empty bodies never enter the index', () {
      final index = _indexWith({
        '!r:test': [
          _record(r'$blank', '   '),
          _record('', '有正文但事件ID为空'),
          _record(r'$ok', '有正文'),
        ],
      });
      expect([for (final hit in index.search('正文')) hit.eventId],
          [r'$ok']);
    });

    test('bounded per room and per account clear', () {
      final index = GlobalSearchIndex(maxRecordsPerRoom: 2, maxRooms: 1);
      index.recordRoom(
        roomId: '!r1:test',
        roomName: 'r1',
        isGroup: false,
        messages: [
          _record(r'$old', '命中', at: DateTime.utc(2026, 9, 1)),
          _record(r'$mid', '命中', at: DateTime.utc(2026, 9, 2)),
          _record(r'$new', '命中', at: DateTime.utc(2026, 9, 3)),
        ],
      );
      expect(index.search('命中').length, 2);
      expect(index.search('命中').first.eventId, r'$new');

      index.recordRoom(
        roomId: '!r2:test',
        roomName: 'r2',
        isGroup: true,
        messages: [_record(r'$other', '命中')],
      );
      expect(index.indexedRoomCount, 1, reason: 'LRU 上限生效');

      index.clear();
      expect(index.indexedRoomCount, 0);
      expect(index.search('命中'), isEmpty);
      expect(index.accountEpoch, 1, reason: '账号切换代次推进');
    });
  });

  group('GlobalSearchController', () {
    GlobalSearchController build(GlobalSearchIndex index,
            {Duration debounce = const Duration(milliseconds: 250),
            int sectionLimit = 3,
            Future<List<GlobalSearchContactResult>> Function()? contacts,
            Future<List<GlobalSearchRoomResult>> Function()? rooms}) =>
        GlobalSearchController(
          loadContacts: contacts ??
              () async => const [
                    GlobalSearchContactResult(
                        userId: 'u1',
                        displayName: '张三',
                        username: 'project-user',
                        matchedText: '畅聊号：project-user'),
                  ],
          loadRooms: rooms ??
              () async => const [
                    GlobalSearchRoomResult(
                        roomId: '!group:test',
                        displayName: '数智经济中心',
                        isDirect: false,
                        memberCount: 8),
                    GlobalSearchRoomResult(
                        roomId: '!dm:test',
                        displayName: '张三',
                        isDirect: true),
                  ],
          index: index,
          debounce: debounce,
          sectionLimit: sectionLimit,
        );

    test('blank query stays clean and immediately clears results', () async {
      final controller = build(_indexWith({
        '!group:test': [_record(r'$hit', '项目文件')],
      }));
      controller.setQuery('项目');
      await controller.refresh();
      expect(controller.hasResults, isTrue);

      controller.setQuery('');
      expect(controller.isBlank, isTrue);
      expect(controller.results.isEmpty, isTrue,
          reason: '空查询不得匹配所有数据');
      controller.dispose();
    });

    test('direct rooms never appear in the group section', () async {
      final controller = build(_indexWith({}));
      controller.setQuery('张');
      await controller.refresh();
      expect([for (final room in controller.results.rooms) room.roomId],
          isEmpty,
          reason: '「张」只匹配到私聊房间，群聊分组必须为空');
      controller.dispose();
    });

    test('sections are limited with more-entries flags', () async {
      final controller = build(
        _indexWith({
          '!group:test': [_record(r'$hit', '项目文件')],
        }),
        sectionLimit: 3,
        rooms: () async => [
          for (var i = 0; i < 5; i++)
            GlobalSearchRoomResult(
                roomId: '!g$i:test', displayName: '项目群$i', isDirect: false),
        ],
        contacts: () async => const [
          GlobalSearchContactResult(
              userId: 'u1', displayName: '项目A', username: 'a'),
          GlobalSearchContactResult(
              userId: 'u2', displayName: '项目B', username: 'b'),
          GlobalSearchContactResult(
              userId: 'u3', displayName: '项目C', username: 'c'),
          GlobalSearchContactResult(
              userId: 'u4', displayName: '项目D', username: 'd'),
        ],
      );
      controller.setQuery('项目');
      await controller.refresh();
      expect(controller.visibleContacts.length, 3);
      expect(controller.hasMoreContacts, isTrue);
      expect(controller.visibleRooms.length, 3);
      expect(controller.hasMoreRooms, isTrue);
      expect(controller.visibleConversations.length, 1);
      controller.dispose();
    });

    test('stale async results never overwrite the newest query', () async {
      final index = _indexWith({
        '!group:test': [
          _record(r'$project', '项目文件'),
          _record(r'$other', '其他内容'),
        ],
      });
      var firstContacts = true;
      final controller = GlobalSearchController(
        loadContacts: () async {
          if (firstContacts) {
            firstContacts = false;
            // 模拟慢请求：a/ab 的迟到结果。
            await Future<void>.delayed(const Duration(milliseconds: 60));
            return const [];
          }
          return const [];
        },
        loadRooms: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return const [];
        },
        index: index,
        debounce: Duration.zero,
      );
      controller.setQuery('项目');
      final slow = controller.refresh();
      controller.setQuery('其他');
      await slow; // 旧代次：不得覆盖
      await controller.refresh();
      expect(controller.query, '其他');
      expect(
          [
            for (final conversation in controller.results.conversations)
              for (final hit in conversation.hits) hit.eventId
          ],
          [r'$other'],
          reason: '迟到请求不得覆盖最新查询结果');
      controller.dispose();
    });

    test('debounce delays execution but eventually publishes', () async {
      final controller = build(
        _indexWith({
          '!group:test': [_record(r'$hit', '项目文件')],
        }),
        debounce: const Duration(milliseconds: 80),
      );
      controller.setQuery('项目');
      expect(controller.hasResults, isFalse, reason: '防抖期间不执行查询');
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(controller.hasResults, isTrue);
      controller.dispose();
    });

    test('loader failure surfaces an error instead of crashing', () async {
      final controller = build(
        _indexWith({}),
        contacts: () async => throw StateError('matrix unavailable'),
      );
      controller.setQuery('张三');
      await controller.refresh();
      expect(controller.error, isNotNull);
      expect(controller.loading, isFalse);
      controller.dispose();
    });

    test('conversation aggregation groups hits per room', () {
      final hits = [
        GlobalSearchMessageHit(
            roomId: '!g:test',
            roomName: '数智经济中心',
            isGroup: true,
            eventId: r'$2',
            senderId: '@a:test',
            senderName: 'A',
            timestamp: DateTime.utc(2026, 9, 15, 11),
            body: '项目2'),
        GlobalSearchMessageHit(
            roomId: '!g:test',
            roomName: '数智经济中心',
            isGroup: true,
            eventId: r'$1',
            senderId: '@b:test',
            senderName: 'B',
            timestamp: DateTime.utc(2026, 9, 15, 10),
            body: '项目1'),
        GlobalSearchMessageHit(
            roomId: '!d:test',
            roomName: '张三',
            isGroup: false,
            eventId: r'$3',
            senderId: '@c:test',
            senderName: 'C',
            timestamp: DateTime.utc(2026, 9, 15, 9),
            body: '项目3'),
      ];
      final conversations = aggregateConversationHits(hits);
      expect(conversations.length, 2);
      expect(conversations.first.roomId, '!g:test');
      expect(conversations.first.total, 2);
      expect(conversations.first.isSingleHit, isFalse);
      expect([for (final hit in conversations.first.hits) hit.eventId],
          [r'$2', r'$1'], reason: '会话内按时间新→旧');
      expect(conversations.last.isSingleHit, isTrue);
    });
  });
}

