import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'matrix_client_factory_test.dart'
    show MatrixTestPaths, SnapshotClient, SnapshotRoom;

/// 同一好友的重复房间：胜者无未读，落选房间挂着历史未读。
final class PrimaryDirectRoom extends SnapshotRoom {
  PrimaryDirectRoom({required super.client, required super.id})
      : super(joined: true);
  @override
  bool get isDirectChat => true;
  @override
  String? get directChatMatrixID => '@peer:test';
}

final class OrphanDirectRoom extends PrimaryDirectRoom {
  OrphanDirectRoom({required super.client, required super.id});
  int unread = 5;
  @override
  int get notificationCount => unread;
}

final class DuplicateUnreadClient extends SnapshotClient {
  DuplicateUnreadClient();
}

void main() {
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
    ConversationReadState.shared().resetForTest();
  });

  test('方案A：落选房间的未读并入主行（duplicateUnreadCount）', () async {
    final client = DuplicateUnreadClient();
    // 胜者（最近活跃）不带未读；落选房间挂着 5 条历史未读 + 一条对方消息。
    final winner = PrimaryDirectRoom(client: client, id: '!new:test');
    final loser = OrphanDirectRoom(client: client, id: '!old:test');
    winner.snapshotEvent = Event(
        room: winner,
        type: EventTypes.Message,
        eventId: r'$win',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026, 9, 18),
        content: {'body': 'latest'});
    loser.snapshotEvent = Event(
        room: loser,
        type: EventTypes.Message,
        eventId: r'$old',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026, 9, 1),
        content: {'body': 'history'});
    client.snapshotRooms
      ..add(loser)
      ..add(winner);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    final snapshot = await matrix.conversations.snapshot();

    expect(snapshot.rooms.single.id, '!new:test');
    expect(snapshot.rooms.single.duplicateUnreadCount, 5,
        reason: '身份解析隐藏了落选房间，其未读必须并入主行，不能凭空消失');
  });

  test('方案A：合并是纯函数——重复解析不叠加', () async {
    final client = DuplicateUnreadClient();
    final winner = PrimaryDirectRoom(client: client, id: '!new:test');
    final loser = OrphanDirectRoom(client: client, id: '!old:test');
    client.snapshotRooms
      ..add(loser)
      ..add(winner);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    final first = await matrix.conversations.snapshot();
    final second = await matrix.conversations.snapshot();

    expect(first.rooms.single.duplicateUnreadCount, 5);
    expect(second.rooms.single.duplicateUnreadCount, 5,
        reason: '每次快照独立计算，不得把上一轮的合并值再叠一轮');
  });

  test('方案A：无落选房间时主行不携带合并未读', () async {
    final client = DuplicateUnreadClient();
    client.snapshotRooms
        .add(PrimaryDirectRoom(client: client, id: '!solo:test'));
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));

    final snapshot = await matrix.conversations.snapshot();

    expect(snapshot.rooms.single.duplicateUnreadCount, 0);
  });
}
