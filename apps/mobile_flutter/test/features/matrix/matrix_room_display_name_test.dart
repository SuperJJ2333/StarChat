import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_room_display_name.dart';

/// 问题五：好友删除/对方退出后，私聊房间无 m.room.name、无 canonical
/// alias，且服务端 summary 的 m.heroes 变为空列表，SDK 的
/// getLocalizedDisplayname() 兜底返回英文 "Empty chat"（聊天页标题、
/// 头像回退、全局搜索等界面直接暴露）。
/// roomDisplayName() 对私聊必须走“对方成员名 → m.direct 对方 ID
/// localpart”回退，永不返回 "Empty chat"；群聊行为保持 SDK 现状。
void main() {
  test('有群名的房间直接返回群名', () {
    final client = _Client();
    final room = _Room(client, roomName: '项目群');
    expect(roomDisplayName(room), '项目群');
  });

  test('对方已退出的私聊（heroes 为空列表）：回退 m.direct 对方成员名', () {
    final client = _Client();
    final room = _Room(
      client,
      directPeer: '@xiaohong:matrix.example',
      memberDisplayNames: {'@xiaohong:matrix.example': '这个小鸿'},
    );
    // 基线：SDK 现状确实返回 "Empty chat"（问题复现）。
    expect(room.getLocalizedDisplayname(), 'Empty chat');
    expect(roomDisplayName(room), '这个小鸿');
  });

  test('成员事件尚未同步：回退 m.direct 对方 ID localpart', () {
    final client = _Client();
    final room = _Room(client, directPeer: '@bob:matrix.example');
    expect(roomDisplayName(room), 'Bob',
        reason: 'localpart 经 formatLocalpart 首字母大写');
  });

  test('既有双人私聊（heroes 正常）照常返回对方名', () {
    final client = _Client();
    final room = _Room(
      client,
      directPeer: '@alice:matrix.example',
      heroes: ['@alice:matrix.example'],
      memberDisplayNames: {'@alice:matrix.example': 'Alice'},
    );
    expect(roomDisplayName(room), 'Alice');
  });

  test('无名群聊沿用 SDK 行为', () {
    final client = _Client();
    final room = _Room(
      client,
      heroes: ['@u1:matrix.example'],
      memberDisplayNames: {'@u1:matrix.example': 'U1'},
    );
    expect(roomDisplayName(room), room.getLocalizedDisplayname());
  });
}

final class _Client extends Fake implements Client {
  @override
  String get userID => '@self:matrix.example';

  @override
  bool get formatLocalpart => true;

  @override
  bool get mxidLocalPartFallback => true;
}

final class _Room extends Room {
  _Room(
    Client client, {
    this.roomName = '',
    this.directPeer,
    this.heroes = const [],
    this.memberDisplayNames = const {},
  }) : super(id: '!r:matrix.example', client: client);

  final String roomName;
  final String? directPeer;
  final List<String> heroes;
  final Map<String, String> memberDisplayNames;

  @override
  String get name => roomName;

  @override
  bool get isDirectChat => directPeer != null;

  @override
  String? get directChatMatrixID => directPeer;

  @override
  RoomSummary get summary =>
      RoomSummary.fromJson({'m.heroes': heroes.toList()});

  @override
  User unsafeGetUserFromMemoryOrFallback(String id) =>
      User(id, room: this, displayName: memberDisplayNames[id]);
}
