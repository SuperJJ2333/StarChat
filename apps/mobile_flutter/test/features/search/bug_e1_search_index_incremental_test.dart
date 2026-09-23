import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/local_message_search_repository.dart';
import 'package:liuhetong_mobile/features/search/room_search_index_scheduler.dart';

GlobalSearchMessageRecord _record(String eventId, {DateTime? at}) =>
    GlobalSearchMessageRecord(
      eventId: eventId,
      senderId: '@peer:test',
      senderName: '对方',
      timestamp: at ?? DateTime(2026, 9, 20),
      body: '内容 $eventId',
      senderIsSelf: false,
    );

void main() {
  test('incremental replacement updates content without losing older history',
      () {
    final index = GlobalSearchIndex(maxRecordsPerRoom: 3);
    void write(List<GlobalSearchMessageRecord> rows) => index.recordRoom(
        roomId: 'room',
        roomName: 'group',
        isGroup: true,
        messages: rows,
        replace: false);
    write([_record('a'), _record('b')]);
    write([
      GlobalSearchMessageRecord(
          eventId: 'a',
          senderId: 'peer',
          senderName: 'peer',
          timestamp: DateTime(2026, 9, 21),
          body: 'corrected')
    ]);
    expect(index.search('corrected').single.eventId, 'a');
    expect(index.search('内容 a'), isEmpty);
    expect(index.search('内容 b').single.eventId, 'b');
    write([
      _record('c', at: DateTime(2026, 9, 22)),
      _record('d', at: DateTime(2026, 9, 23))
    ]);
    expect(index.search('内容 b'), isEmpty, reason: 'oldest is evicted');
    expect(index.search('corrected').single.eventId, 'a');
    index.removeMessages(['a']);
    expect(index.search('corrected'), isEmpty);
  });
  test('E1：索引支持按 eventId 删除（撤回不再可被搜索到）', () {
    final index = GlobalSearchIndex.shared..clear();
    index.recordRoom(
      roomId: '!room:test',
      roomName: '群聊',
      isGroup: true,
      messages: [_record(r'$a'), _record(r'$b'), _record(r'$c')],
    );
    expect(index.search('内容', limit: 10).length, 3);

    index.removeMessages([r'$b']);
    final hits = index.search('内容', limit: 10);
    expect(hits.length, 2, reason: '被删的事件不得再命中');
    expect(hits.every((hit) => hit.eventId != r'$b'), isTrue);
  });

  test('E1：仓库层删除并通知监听者', () {
    final repository = LocalMessageSearchRepository.shared..clear();
    var notified = 0;
    repository.addListener(() => notified++);
    repository.recordRoomMessages([
      LocalSearchMessage(
        eventId: 'e1',
        senderId: '@peer:test',
        senderName: '对方',
        timestamp: DateTime(2026, 9, 20),
        body: '机密正文',
        roomId: '!room:test',
        roomName: '私聊',
        isGroup: false,
        senderIsSelf: false,
      ),
      LocalSearchMessage(
        eventId: 'e2',
        senderId: '@peer:test',
        senderName: '对方',
        timestamp: DateTime(2026, 9, 20),
        body: '普通正文',
        roomId: '!room:test',
        roomName: '私聊',
        isGroup: false,
        senderIsSelf: false,
      ),
    ]);
    expect(repository.search('正文'), hasLength(2));

    repository.removeMessages(['e1']);
    expect(notified, greaterThan(0));
    final hits = repository.search('正文');
    expect(hits, hasLength(1));
    expect(hits.single.eventId, 'e2', reason: '撤回的消息正文必须从索引移除');
  });

  test('E1：增量调度器——重复 id 只提交一次、echo 不提交、撤回转删除', () {
    final scheduler = RoomSearchIndexScheduler();
    final first = scheduler.observe(
      seenIds: const ['a', 'b', 'echo'],
      indexableIds: const {'a', 'b'},
      recalledIds: const {},
    );
    expect(first.toIndex, unorderedEquals(['a', 'b']), reason: 'echo 只登记不提交');
    expect(first.toRemove, isEmpty);

    final second = scheduler.observe(
      seenIds: const ['a', 'b', 'echo', 'c'],
      indexableIds: const {'c'},
      recalledIds: const {'b'},
    );
    expect(second.toIndex, ['c'], reason: '增量：只提交新出现的消息');
    expect(second.toRemove, ['b'], reason: '撤回的已索引消息必须转删除');
  });
}
