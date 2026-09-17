import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_home_page.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'matrix_client_factory_test.dart' show SnapshotClient, SnapshotRoom;

/// 私聊房间夹具：`isDirectChat` 为真，最后一条事件与未读数可切换。
class LocalClearRoom extends SnapshotRoom {
  LocalClearRoom({required super.id, required super.client})
      : super(joined: true);
  @override
  bool get isDirectChat => true;
  @override
  int get notificationCount => unread;
  int unread = 3;
}

Event _message(Room room, String id, DateTime at) => Event(
      room: room,
      type: EventTypes.Message,
      eventId: id,
      senderId: '@peer:test',
      originServerTs: at,
      content: {'msgtype': MessageTypes.Text, 'body': 'fixture'},
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('清空聊天记录只清本机历史，会话仍留在消息列表', () async {
    final client = SnapshotClient();
    final room = LocalClearRoom(id: '!direct:test', client: client);
    final last = _message(room, 'm1', DateTime.utc(2026, 9, 1));
    room.snapshotEvent = last;
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.clearLocalHistory(
      room.id,
      messageIds: const ['m1'],
      cutoff: last.originServerTs,
    );

    final snapshot = (await matrix.conversations.snapshot()).rooms.single;
    expect(snapshot.preference.hidden, isFalse, reason: '清空聊天记录不得把会话从消息列表移除');
    expect(snapshot.lastEvent, isNull, reason: '被清空的本地历史不可见');
    expect(snapshot.notificationCount, 0, reason: '清空后该会话未读清零');
  });

  test('清空截止时间同时隐藏未在本机逐条标记的历史消息', () async {
    final client = SnapshotClient();
    final room = LocalClearRoom(id: '!direct:test', client: client);
    final last = _message(room, 'm1', DateTime.utc(2026, 9, 1));
    room.snapshotEvent = last;
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    // 未加载到本机的历史没有逐条 hide 记录，只能靠截止时间隐藏。
    await matrix.conversations.clearLocalHistory(
      room.id,
      messageIds: const [],
      cutoff: last.originServerTs,
    );

    final snapshot = (await matrix.conversations.snapshot()).rooms.single;
    expect(snapshot.lastEvent, isNull, reason: '截止时间必须覆盖未逐条标记的历史');
    expect(snapshot.preference.hidden, isFalse);
  });

  test('清空聊天记录后收到新消息，会话与新消息都正常显示', () async {
    final client = SnapshotClient();
    final room = LocalClearRoom(id: '!direct:test', client: client);
    final last = _message(room, 'm1', DateTime.utc(2026, 9, 1));
    room.snapshotEvent = last;
    client.snapshotRooms.add(room);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    await matrix.conversations.clearLocalHistory(
      room.id,
      messageIds: const ['m1'],
      cutoff: last.originServerTs,
    );

    room.snapshotEvent = _message(
        room, 'm2', last.originServerTs.add(const Duration(minutes: 1)));
    room.unread = 1;

    final snapshot = (await matrix.conversations.snapshot()).rooms.single;
    expect(snapshot.preference.hidden, isFalse);
    expect(snapshot.lastEvent!.eventId, 'm2', reason: '新消息必须重新可见');
    expect(snapshot.notificationCount, 1, reason: '新消息的未读必须恢复');
  });

  test('清空聊天记录后该会话在消息列表中的位置不变（不掉到末尾）', () async {
    final client = SnapshotClient();
    final newest = LocalClearRoom(id: '!newest:test', client: client);
    final older = LocalClearRoom(id: '!older:test', client: client);
    final newestEvent = _message(newest, 'n1', DateTime.utc(2026, 9, 3));
    final olderEvent = _message(older, 'o1', DateTime.utc(2026, 9, 2));
    newest.snapshotEvent = newestEvent;
    older.snapshotEvent = olderEvent;
    client.snapshotRooms.addAll([older, newest]);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    // 与「消息」页完全相同的排序链路：快照 → 排序锚点 → orderConversations。
    List<String> order(Iterable<MatrixConversationRoomSnapshot> rooms) => [
          for (final item in orderConversations([
            for (final room in rooms)
              ConversationProjection(
                roomId: room.id,
                isGroup: !room.isDirect,
                lastActivity: conversationSortAnchor(room),
                preference: room.preference,
              ),
          ]))
            item.roomId,
        ];

    final before = (await matrix.conversations.snapshot()).rooms;
    expect(order(before), ['!newest:test', '!older:test']);

    await matrix.conversations.clearLocalHistory(
      newest.id,
      messageIds: const ['n1'],
      cutoff: newestEvent.originServerTs,
    );

    final after = (await matrix.conversations.snapshot()).rooms;
    expect(after.singleWhere((room) => room.id == newest.id).lastEvent, isNull,
        reason: '被清空的本地历史不可见');
    expect(
        conversationSortAnchor(
            after.singleWhere((room) => room.id == newest.id)),
        newestEvent.originServerTs,
        reason: '排序锚点必须保留清空前的最后活动时间');
    expect(order(after), ['!newest:test', '!older:test'],
        reason: '清空聊天记录不得把该会话排到消息列表末尾');
  });
}
