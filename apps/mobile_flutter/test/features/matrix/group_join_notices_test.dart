import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/matrix/group_join_notices.dart';
import 'package:liuhetong_mobile/features/matrix/room_timeline_controller.dart';

/// BUG3：入群系统通知推导——以真实成员事件投影为唯一权威（纯函数）。
void main() {
  final names = {'@alice:x': '张三', '@bob:x': '李四', '@carol:x': '王五'};
  String resolve(String id) => names[id] ?? id;

  MembershipEventFacts member(
    String stateKey,
    String membership, {
    required String sender,
    String? prev,
    bool qr = false,
    DateTime? at,
  }) =>
      MembershipEventFacts(
        eventId: 'evt-$stateKey-$membership-$prev',
        stateKey: stateKey,
        senderId: sender,
        membership: membership,
        prevMembership: prev,
        joinSource: qr ? 'qr' : null,
        timestamp: at ?? DateTime.fromMillisecondsSinceEpoch(0),
      );

  test('invite 配对 join → "张三邀请李四加入群聊"', () {
    final notices = deriveGroupJoinNotices(
      [
        member('@alice:x', 'join', sender: '@alice:x'),
        member('@bob:x', 'invite', sender: '@alice:x'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'invite'),
      ],
      resolveName: resolve,
    );
    expect(notices.length, 1);
    expect(notices.single.text, '张三邀请李四加入群聊');
  });

  test('仅 invite 未 join → 不显示任何通知', () {
    final notices = deriveGroupJoinNotices(
      [
        member('@alice:x', 'join', sender: '@alice:x'),
        member('@bob:x', 'invite', sender: '@alice:x'),
      ],
      resolveName: resolve,
    );
    expect(notices, isEmpty, reason: '未真正加入不得显示"已加入"');
  });

  test('join→join 资料变更不重复通知（去重）', () {
    final notices = deriveGroupJoinNotices(
      [
        member('@bob:x', 'invite', sender: '@alice:x'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'invite'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'join'),
      ],
      resolveName: resolve,
    );
    expect(notices.length, 1);
  });

  test('扫码加入标记 → "李四通过扫描二维码加入群聊"', () {
    final notices = deriveGroupJoinNotices(
      [member('@bob:x', 'join', sender: '@bob:x', prev: 'invite', qr: true)],
      resolveName: resolve,
    );
    expect(notices.single.text, '李四通过扫描二维码加入群聊');
  });

  test('建群首成员（自邀自/无 invite）不产生通知', () {
    final notices = deriveGroupJoinNotices(
      [member('@alice:x', 'join', sender: '@alice:x')],
      resolveName: resolve,
    );
    expect(notices, isEmpty);
  });

  test('相邻同邀请者合并为批量文案', () {
    final notices = deriveGroupJoinNotices(
      [
        member('@bob:x', 'invite', sender: '@alice:x'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'invite'),
        member('@carol:x', 'invite', sender: '@alice:x'),
        member('@carol:x', 'join', sender: '@carol:x', prev: 'invite'),
      ],
      resolveName: resolve,
    );
    final messages = mergeNoticesIntoTimeline(const [], notices);
    expect(messages.length, 1);
    expect(messages.single.text, '张三邀请李四、王五加入群聊');
    expect(messages.single.kind, RoomMessageKind.system);
  });

  test('通知按时间插入消息流且保持消息顺序', () {
    final base = DateTime.fromMillisecondsSinceEpoch(1000);
    final notices = deriveGroupJoinNotices(
      [
        member('@bob:x', 'invite', sender: '@alice:x'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'invite',
            at: base.add(const Duration(minutes: 5))),
      ],
      resolveName: resolve,
    );
    RoomMessageViewModel text(String id, DateTime at, String body) =>
        RoomMessageViewModel(
          id: id,
          senderId: '@peer:x',
          text: body,
          isOwn: false,
          deliveryState: RoomDeliveryState.sent,
          timestamp: at,
          kind: RoomMessageKind.text,
        );
    final merged = mergeNoticesIntoTimeline(
      [text('m1', base, '第一条'), text('m2', base.add(const Duration(minutes: 10)), '第二条')],
      notices,
    );
    expect(merged.map((m) => m.text).toList(),
        ['第一条', '张三邀请李四加入群聊', '第二条']);
  });

  test('不同邀请者不合并', () {
    final notices = deriveGroupJoinNotices(
      [
        member('@bob:x', 'invite', sender: '@alice:x'),
        member('@bob:x', 'join', sender: '@bob:x', prev: 'invite'),
        member('@carol:x', 'invite', sender: '@dave:x'),
        member('@carol:x', 'join', sender: '@carol:x', prev: 'invite'),
      ],
      resolveName: resolve,
    );
    final messages = mergeNoticesIntoTimeline(const [], notices);
    expect(messages.map((m) => m.text).toList(), [
      '张三邀请李四加入群聊',
      '@dave:x邀请王五加入群聊',
    ]);
  });
}
