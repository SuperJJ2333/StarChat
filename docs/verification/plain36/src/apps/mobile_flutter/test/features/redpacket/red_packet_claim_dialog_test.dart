import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_dialog.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_controller.dart';

final class FakeRedPacketViewGateway implements RedPacketViewGateway {
  FakeRedPacketViewGateway({
    required this.detail,
    this.claimAmount = '8.88',
    this.claimError,
    this.contacts = const <ContactSummary>[],
  });

  Map<String, dynamic> detail;
  String claimAmount;
  Object? claimError;
  List<ContactSummary> contacts;
  int claimCalls = 0;

  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async => detail;

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async {
    claimCalls++;
    final failure = claimError;
    if (failure != null) throw failure;
    return {'share_id': 'share-1', 'amount': claimAmount, 'asset': 'CAIBI'};
  }

  @override
  Future<List<ContactSummary>> listContacts() async => contacts;
}

const _openDetail = {
  'id': 'packet-1',
  'sender_id': 'u-bob',
  'total': '88.00',
  'share_count': 10,
  'claimed_count': 0,
  'status': 'OPEN',
  'claims': <Map<String, dynamic>>[],
};

Future<void> _openDialog(
  WidgetTester tester, {
  required FakeRedPacketViewGateway gateway,
}) async {
  await tester.pumpWidget(CupertinoApp(
    home: Builder(
      builder: (context) => CupertinoButton(
        onPressed: () => showRedPacketClaimDialog(
          context,
          api: gateway,
          packetId: 'packet-1',
          senderName: '项目小艾',
        ),
        child: const Text('打开红包'),
      ),
    ),
  ));
  await tester.tap(find.text('打开红包'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('claim dialog centers with 開 button and luck entry',
      (tester) async {
    await _openDialog(tester, gateway: FakeRedPacketViewGateway(detail: _openDetail));

    expect(find.byKey(const Key('red-packet-claim-dialog')), findsOneWidget);
    expect(find.text('開'), findsOneWidget);
    expect(find.text('项目小艾的红包'), findsOneWidget);
    expect(find.text('看看大家的手气 >'), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-close')), findsOneWidget);

    // The dialog card is horizontally centered, just above the X button.
    final center = tester.getCenter(find.byKey(const Key('red-packet-claim-dialog')));
    final appSize = tester.getSize(find.byType(CupertinoApp));
    expect(center.dx, closeTo(appSize.width / 2, 1));
    expect(center.dy, lessThan(appSize.height / 2));
    expect(center.dy, greaterThan(appSize.height / 4));
  });

  testWidgets('tapping 開 claims and shows the credited amount',
      (tester) async {
    final gateway = FakeRedPacketViewGateway(detail: _openDetail);
    await _openDialog(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();

    expect(gateway.claimCalls, 1);
    expect(find.byKey(const Key('red-packet-claim-result')), findsOneWidget);
    expect(find.text('已领取 8.88 点钻，存入点钻余额'), findsOneWidget);
  });

  testWidgets('claim errors surface inline and keep the dialog open',
      (tester) async {
    final gateway = FakeRedPacketViewGateway(
      detail: _openDetail,
      claimError: Exception('手慢了，红包已被领完'),
    );
    await _openDialog(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('手慢了，红包已被领完'), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-dialog')), findsOneWidget);
  });

  testWidgets('tapping outside or the X closes the dialog', (tester) async {
    final gateway = FakeRedPacketViewGateway(detail: _openDetail);
    await _openDialog(tester, gateway: gateway);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('red-packet-claim-dialog')), findsNothing);

    await _openDialog(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('red-packet-claim-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('red-packet-claim-dialog')), findsNothing);
  });

  testWidgets('看看大家的手气 opens the claim detail page', (tester) async {
    final gateway = FakeRedPacketViewGateway(
      detail: {
        ..._openDetail,
        'claimed_count': 1,
        'claims': [
          {
            'user_id': 'u-bob',
            'amount': '8.88',
            'claimed_at': '2026-08-29T10:00:00Z',
          },
        ],
      },
      contacts: const [
        ContactSummary(
          userId: 'u-bob',
          username: 'bob',
          matrixUserId: '@bob:test',
          nickname: '波仔',
          remark: '项目小艾',
        ),
      ],
    );
    await _openDialog(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-luck-entry')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('red-packet-claim-detail-page')),
        findsOneWidget);
    expect(find.text('项目小艾的红包'), findsOneWidget);
  });
}
