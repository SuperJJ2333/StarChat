import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/room_navigation_coordinator.dart';
import 'package:liuhetong_mobile/features/search/global_search_controller.dart';
import 'package:liuhetong_mobile/features/search/global_search_index.dart';
import 'package:liuhetong_mobile/features/search/global_search_models.dart';

GlobalSearchMessageRecord _record(String id, String body, DateTime at) =>
    GlobalSearchMessageRecord(
      eventId: id,
      senderId: '@peer:test',
      senderName: '好友A',
      timestamp: at,
      body: body,
    );

GlobalSearchIndex _index() {
  final index = GlobalSearchIndex();
  index.recordRoom(
    roomId: '!orphan:test',
    roomName: '好友A',
    isGroup: false,
    messages: [_record(r'$in-orphan', '孤儿房间命中', DateTime.utc(2026, 9, 18))],
  );
  index.recordRoom(
    roomId: '!primary:test',
    roomName: '好友A',
    isGroup: false,
    messages: [_record(r'$in-primary', '主房间命中', DateTime.utc(2026, 9, 1))],
  );
  return index;
}

void main() {
  test('项3：孤儿房间命中归并到主会话名下，命中保留 sourceRoomId', () {
    final hits = [
      _hit('!orphan:test', r'$in-orphan', DateTime.utc(2026, 9, 18)),
      _hit('!primary:test', r'$in-primary', DateTime.utc(2026, 9, 1)),
    ];
    final aggregated = aggregateConversationHits(hits,
        primaryRoomIdOf: (roomId) =>
            roomId == '!orphan:test' ? '!primary:test' : null);
    expect(aggregated, hasLength(1), reason: '同一好友只出现一个逻辑会话分组');
    expect(aggregated.single.roomId, '!primary:test');
    // 命中保留来源房间：定位时能区分消息物理所在房间（sourceRoomId）。
    expect(aggregated.single.hits.map((hit) => hit.roomId).toSet(),
        {'!orphan:test', '!primary:test'});
    expect(aggregated.single.latest.eventId, r'$in-orphan',
        reason: '组内按时间倒序，最新命中优先');
  });

  test('项3：无映射的房间保持独立分组（不误归并）', () {
    final hits = [
      _hit('!a:test', r'$a', DateTime.utc(2026, 9, 18)),
      _hit('!b:test', r'$b', DateTime.utc(2026, 9, 1)),
    ];
    final aggregated =
        aggregateConversationHits(hits, primaryRoomIdOf: (_) => null);
    expect(
        aggregated.map((entry) => entry.roomId).toSet(), {'!a:test', '!b:test'});
  });

  test('项3：normalizeDuplicateRoomOpen 仅对搜索/通知来源的孤儿房间置只读',
      () {
        RoomOpenRequest request(RoomOpenSource source) => RoomOpenRequest(
            roomId: '!orphan:test',
            roomName: '好友A',
            anchorEventId: r'$in-orphan',
            source: source);

        final searchReadOnly = normalizeDuplicateRoomOpen(
            request(RoomOpenSource.search),
            isDuplicateRoom: (roomId) => roomId == '!orphan:test');
        expect(searchReadOnly.readOnly, isTrue);
        expect(searchReadOnly.roomId, '!orphan:test',
            reason: '只读归一化保留 sourceRoomId 定位');
        expect(searchReadOnly.anchorEventId, r'$in-orphan');

        expect(
            normalizeDuplicateRoomOpen(request(RoomOpenSource.notification),
                isDuplicateRoom: (roomId) => roomId == '!orphan:test').readOnly,
            isTrue);
        // 非孤儿房间：不变。
        expect(
            normalizeDuplicateRoomOpen(request(RoomOpenSource.search),
                    isDuplicateRoom: (_) => false)
                .readOnly,
            isFalse);
        // 其他来源（好友资料/消息列表）即使命中登记表也不置只读——它们走
        // canonical 解析，不会落在孤儿房间上。
        expect(
            normalizeDuplicateRoomOpen(
                    request(RoomOpenSource.contactProfile),
                    isDuplicateRoom: (_) => true)
                .readOnly,
            isFalse);
      });

  test('项3：控制器接线——命中按逻辑会话归组', () async {
    final controller = GlobalSearchController(
      loadContacts: () async => const [],
      loadRooms: () async => const [],
      index: _index(),
      primaryRoomIdOf: (roomId) async =>
          roomId == '!orphan:test' ? '!primary:test' : null,
    );
    addTearDown(controller.dispose);
    controller.setQuery('命中');
    await controller.refresh();
    expect(controller.results.conversations, hasLength(1),
        reason: '孤儿房间与主房间的命中归并进同一逻辑会话');
    expect(controller.results.conversations.single.roomId, '!primary:test');
    expect(controller.results.conversations.single.hits, hasLength(2));
  });
}

GlobalSearchMessageHit _hit(String roomId, String eventId, DateTime at) =>
    GlobalSearchMessageHit(
      roomId: roomId,
      roomName: '好友A',
      isGroup: false,
      eventId: eventId,
      senderId: '@peer:test',
      senderName: '好友A',
      timestamp: at,
      body: '命中 $eventId',
    );
