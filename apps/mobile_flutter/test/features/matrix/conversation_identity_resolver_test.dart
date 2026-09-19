import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_identity_resolver.dart';
import 'package:liuhetong_mobile/features/matrix/conversation_preferences.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';

MatrixConversationRoomSnapshot directRoom(
  String id,
  String peer, {
  DateTime? lastActivity,
  ConversationPreference preference = const ConversationPreference(),
}) =>
    MatrixConversationRoomSnapshot(
      id: id,
      displayName: id,
      avatar: null,
      isDirect: true,
      directPeerId: peer,
      members: const [],
      lastEvent: null,
      preference: preference,
      notificationCount: 0,
      notificationsEnabled: true,
      name: id,
      isJoined: true,
      lastActivityAt: lastActivity,
    );

MatrixConversationRoomSnapshot groupRoom(String id, {DateTime? lastActivity}) =>
    MatrixConversationRoomSnapshot(
      id: id,
      displayName: id,
      avatar: null,
      isDirect: false,
      directPeerId: null,
      members: const [],
      lastEvent: null,
      preference: const ConversationPreference(),
      notificationCount: 0,
      notificationsEnabled: true,
      name: id,
      isJoined: true,
      lastActivityAt: lastActivity,
    );

void main() {
  test('同一好友的两个私聊房间只保留最近活跃的一行', () {
    final rooms = [
      groupRoom('!group:test'),
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.map((room) => room.id), ['!group:test', '!new:test'],
        reason: '同一好友（m.direct 双映射）只允许出现一行，且保留最近活跃的房间');
  });

  test('canonical room 存在时 canonical 优先（高于消息数与活跃度）', () {
    final rooms = [
      directRoom('!busy:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
      directRoom('!canonical:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
    ];
    final resolved = resolveConversationIdentities(
      rooms,
      selfUserId: '@me:test',
      primaryRoomIdOf: (_) => '!canonical:test',
    );
    expect(resolved.single.id, '!canonical:test',
        reason: '服务端 canonical 映射是最高优先级（规则一）');
  });

  test('旧 room 消息更多时选择消息更多的 room（避免进入空白新房间）', () {
    final rooms = [
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
    ];
    final resolved = resolveConversationIdentities(
      rooms,
      selfUserId: '@me:test',
      localMessageCountOf: (room) => room.id == '!old:test' ? 42 : 0,
    );
    expect(resolved.single.id, '!old:test',
        reason: 'canonical 未决时，本地消息数量优先于活跃度（规则二）');
  });

  test('消息数相同时回到活跃度规则；canonical 指向的房间不在候选中时忽略', () {
    final rooms = [
      directRoom('!a:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
      directRoom('!b:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
    ];
    final resolved = resolveConversationIdentities(
      rooms,
      selfUserId: '@me:test',
      localMessageCountOf: (_) => 7,
      primaryRoomIdOf: (_) => '!elsewhere:test',
    );
    expect(resolved.single.id, '!a:test',
        reason: '消息数打平且 canonical 未命中候选时，按活跃度裁决');
  });

  test('两个重复私聊都没有活动时间时按 roomId 字典序确定胜者', () {
    final rooms = [
      directRoom('!zzz:test', '@peer:test'),
      directRoom('!aaa:test', '@peer:test'),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.single.id, '!aaa:test');
    // 再反序输入，胜者必须稳定（确定性规则，不能依赖列表顺序）。
    expect(
        resolveConversationIdentities(rooms.reversed.toList(),
                selfUserId: '@me:test')
            .single
            .id,
        '!aaa:test');
  });

  test('不同好友的私聊互不去重，身份 key 为排序后的 userId 对', () {
    final rooms = [
      directRoom('!a:test', '@alice:test'),
      directRoom('!b:test', '@bob:test'),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.length, 2);
    // key 与方向无关：同一线路的正反投影是同一个 key。
    expect(
        directConversationIdentityKey(
            selfUserId: '@me:test', peerId: '@alice:test'),
        directConversationIdentityKey(
            selfUserId: '@alice:test', peerId: '@me:test'));
  });

  test('directPeerId 缺失的私聊不得作为独立可见行泄漏', () {
    final rooms = [
      directRoom('!x:test', ''),
      directRoom('!y:test', ''),
      directRoom('!peer:test', '@peer:test'),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.map((room) => room.id).toSet(), {'!peer:test'});
  });

  test('群聊按 roomId 出行，永不与私聊混淆', () {
    final rooms = [
      groupRoom('!g1:test'),
      groupRoom('!g2:test'),
      directRoom('!g1-dup:test', '@peer:test'),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.length, 3);
  });

  test('解析是幂等的：对输出再次解析不产生变化', () {
    final rooms = [
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
      groupRoom('!group:test'),
    ];
    final once = resolveConversationIdentities(rooms, selfUserId: '@me:test');
    final twice = resolveConversationIdentities(once, selfUserId: '@me:test');
    expect(once.map((room) => room.id).toList(),
        twice.map((room) => room.id).toList());
  });

  test('详细解析返回落选房间按主房间分组（未读并入主行的数据源）', () {
    final rooms = [
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
      groupRoom('!group:test'),
    ];
    final resolution = resolveConversationIdentitiesDetailed(
      rooms,
      selfUserId: '@me:test',
    );
    expect(resolution.representatives.map((room) => room.id).toList(),
        ['!new:test', '!group:test']);
    expect(resolution.duplicatesByRepresentativeId['!new:test']!.single.id,
        '!old:test',
        reason: '落选房间必须挂在其主房间名下，供未读并入');
    expect(resolution.duplicatesByRepresentativeId.containsKey('!group:test'),
        isFalse,
        reason: '无落选者的主房间不得出现空分组');
  });

  test('被本机隐藏（删除该聊天）的重复房间不得压制可见房间', () {
    final rooms = [
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18),
          preference: const ConversationPreference(hidden: true)),
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.single.id, '!old:test',
        reason: '隐藏房间不参与胜者竞争，也不会让另一个重复房间凭空消失');
  });

  test('快照契约：单独被隐藏的会话仍保留在快照中（隐藏过滤归 UI 层）', () {
    final rooms = [
      directRoom('!hidden:test', '@peer:test',
          preference: const ConversationPreference(hidden: true)),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.single.id, '!hidden:test',
        reason: '身份解析不是隐藏过滤器；local_conversation_delete 等契约依赖隐藏会话仍在快照内');
  });

  test('输出保持输入的相对顺序', () {
    final rooms = [
      groupRoom('!g1:test'),
      directRoom('!new:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 18)),
      directRoom('!old:test', '@peer:test',
          lastActivity: DateTime.utc(2026, 9, 1)),
      groupRoom('!g2:test'),
    ];
    final resolved =
        resolveConversationIdentities(rooms, selfUserId: '@me:test');
    expect(resolved.map((room) => room.id).toList(),
        ['!g1:test', '!new:test', '!g2:test']);
  });
}
