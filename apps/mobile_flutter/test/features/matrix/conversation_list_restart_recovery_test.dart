import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_read_state.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'matrix_client_factory_test.dart'
    show MatrixTestPaths, SnapshotClient, SnapshotRoom;

/// m.direct 中同一好友登记的已加入房间（重复会话缺陷的实际数据形态）。
final class DirectSnapshotRoom extends SnapshotRoom {
  DirectSnapshotRoom(
      {required super.id, required super.client, required this.peer})
      : super(joined: true);
  final String peer;
  @override
  bool get isDirectChat => true;
  @override
  String? get directChatMatrixID => peer;
}

/// 模拟「冷启动后 SDK 从 SQLite 恢复出同一好友的两个 joined 房间」：
/// 该形态来自历史房间/旧版本建房/avoidRoomId 显式新建（见缺陷计划文档一节）。
final class DuplicateDirectoryClient extends SnapshotClient {
  DuplicateDirectoryClient();
}

Future<List<String>> restoredSnapshotRoomIds() async {
  final client = DuplicateDirectoryClient();
  client.snapshotRooms.add(DirectSnapshotRoom(
      id: '!old:test', client: client, peer: '@peer:test'));
  client.snapshotRooms.add(DirectSnapshotRoom(
      id: '!new:test', client: client, peer: '@peer:test'));
  client.snapshotRooms
      .add(SnapshotRoom(id: '!group:test', client: client, joined: true));
  final matrix =
      MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
  final snapshot = await matrix.conversations.snapshot();
  return [for (final room in snapshot.rooms) room.id];
}

void main() {
  setUp(() {
    PathProviderPlatform.instance = MatrixTestPaths();
    SharedPreferences.setMockInitialValues({});
    ConversationReadState.shared().resetForTest();
  });

  test('测试1的前置（重启恢复）：恢复出同一好友两个房间时快照只含一行', () async {
    expect(await restoredSnapshotRoomIds(), ['!new:test', '!group:test'],
        reason: '同一好友（m.direct 双映射）在数据源层就必须去重为一行，保留最近活跃房间');
  });

  test('测试3：二次冷启动（App 重启恢复）列表仍唯一', () async {
    final firstBoot = await restoredSnapshotRoomIds();
    final secondBoot = await restoredSnapshotRoomIds();
    expect(firstBoot, ['!new:test', '!group:test']);
    expect(secondBoot, firstBoot, reason: '重启恢复不得让重复会话复活');
  });
}
