import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_controller.dart';

final class FakeGateway implements RedPacketViewGateway {
  FakeGateway({required this.detail, this.contacts = const []});

  final Map<String, dynamic> detail;
  final List<ContactSummary> contacts;

  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async => detail;

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async => {};

  @override
  Future<List<ContactSummary>> listContacts() async => contacts;
}

const _contacts = [
  ContactSummary(
    userId: 'u-bob',
    username: 'bob',
    matrixUserId: '@bob:test',
    nickname: '波仔',
    remark: '项目小艾',
  ),
  ContactSummary(
    userId: 'u-alice',
    username: 'alice',
    matrixUserId: '@alice:test',
    nickname: '艾米',
  ),
];

final _detail = {
  'id': 'packet-1',
  'sender_id': 'u-alice',
  'total': '88.00',
  'share_count': 3,
  'claimed_count': 3,
  'status': 'COMPLETED',
  'claims': [
    {
      'user_id': 'u-bob',
      'amount': '30.00',
      'claimed_at': '2026-08-29T10:00:00Z',
    },
    {
      'user_id': 'u-alice',
      'amount': '40.00',
      'claimed_at': '2026-08-29T10:01:00Z',
    },
    {
      'user_id': 'u-carol',
      'amount': '18.00',
      'claimed_at': '2026-08-29T10:02:00Z',
    },
  ],
};

Future<void> _pumpPage(WidgetTester tester, FakeGateway gateway) async {
  await tester.pumpWidget(CupertinoApp(
    home: RedPacketClaimDetailPage(api: gateway, packetId: 'packet-1'),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('claims parse in ascending claim-time order', () {
    final records = parseRedPacketClaims(_detail);
    expect(records.map((record) => record.userId).toList(),
        ['u-bob', 'u-alice', 'u-carol']);
    expect(records[1].amount, '40.00');
  });

  test('claims parse public profile fields for display', () {
    final records = parseRedPacketClaims({
      'claims': [
        {
          'user_id': 'u-carol',
          'amount': '18.00',
          'nickname': '卡罗尔',
          'username': 'carol_88',
          'avatar_url': 'https://cdn.example.com/avatar-carol.jpg',
        },
      ],
    });
    expect(records.single.nickname, '卡罗尔');
    expect(records.single.username, 'carol_88');
    expect(records.single.avatarUrl, 'https://cdn.example.com/avatar-carol.jpg');
  });

  test('display name prefers remark, then nickname, then username', () {
    expect(
      redPacketDisplayName(
          remarkName: '备注名', nickname: '昵称', username: 'user01'),
      '备注名',
      reason: '备注仅查看者本人可见，但优先展示',
    );
    expect(
      redPacketDisplayName(nickname: '昵称', username: 'user01'),
      '昵称',
    );
    expect(redPacketDisplayName(username: 'user01'), 'user01');
    expect(redPacketDisplayName(), '好友');
  });

  test('best luck marks the highest amount', () {
    final records = parseRedPacketClaims(_detail);
    expect(bestLuckRecordIndex(records), 1);
    expect(bestLuckRecordIndex(const []), isNull);
  });

  testWidgets('detail page shows totals, sender and claim records',
      (tester) async {
    await _pumpPage(tester, FakeGateway(detail: _detail, contacts: _contacts));

    expect(
        find.text('共 88.00 点钻，已领取 3/3 个'), findsOneWidget);
    // Sender resolved with remark priority from the viewer's contact book.
    expect(find.text('艾米的红包'), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-records')), findsOneWidget);
    // Records render with remark priority for the viewer.
    expect(find.text('项目小艾'), findsOneWidget);
    expect(find.text('30.00点钻'), findsOneWidget);
    expect(find.text('40.00点钻'), findsOneWidget);
    // 手气最佳 badge appears exactly once, on the highest record.
    expect(find.byKey(const Key('luck-best-badge')), findsOneWidget);
    final badge = tester.getTopLeft(find.byKey(const Key('luck-best-badge')));
    final record = tester.getTopLeft(
        find.byKey(const Key('red-packet-claim-record-u-alice')));
    expect(badge.dy >= record.dy, isTrue);
  });

  testWidgets('unknown claimers fall back to 好友 and empty packets show a hint',
      (tester) async {
    await _pumpPage(tester, FakeGateway(detail: {
      ..._detail,
      'claimed_count': 0,
      'status': 'OPEN',
      'claims': const [],
    }, contacts: _contacts));

    expect(find.text('暂无领取记录'), findsOneWidget);
  });

  testWidgets('payload profile fills names for non-contact claimers, '
      'remark still wins for contacts', (tester) async {
    await _pumpPage(tester, FakeGateway(detail: {
      ..._detail,
      'sender_id': 'u-sender9',
      'sender_nickname': '梅发送者',
      'sender_username': 'sender09',
      'sender_avatar_url': 'https://cdn.example.com/avatar-sender.jpg',
      'claims': [
        {
          'user_id': 'u-bob',
          'amount': '30.00',
          'claimed_at': '2026-08-29T10:00:00Z',
          'nickname': '鲍勃昵称',
          'username': 'bob88',
          'avatar_url': 'https://cdn.example.com/avatar-bob.jpg',
        },
        {
          'user_id': 'u-stranger',
          'amount': '58.00',
          'claimed_at': '2026-08-29T10:01:00Z',
          'nickname': '路人甲',
          'username': 'stranger01',
          'avatar_url': 'https://cdn.example.com/avatar-stranger.jpg',
        },
      ],
    }, contacts: _contacts));

    // 非好友领取人：展示服务端昵称（无备注可覆盖）。
    expect(find.text('路人甲'), findsOneWidget);
    // 有备注的联系人：备注优先于服务端昵称。
    expect(find.text('项目小艾'), findsOneWidget);
    // 发送人不在联系人列表：回退服务端公开昵称。
    expect(find.text('梅发送者的红包'), findsOneWidget);
  });

  testWidgets('non-open packets explain the status', (tester) async {
    await _pumpPage(tester, FakeGateway(detail: {
      ..._detail,
      'status': 'EXPIRED',
    }, contacts: _contacts));

    expect(find.text('已过期，未领取金额将退回'), findsOneWidget);
  });
}
