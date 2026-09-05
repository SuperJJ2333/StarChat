import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_controller.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_sheet.dart';

final class FakeTransferBusiness implements ChatTransferBusinessGateway {
  int creates = 0;
  String? receiverId;
  String? amount;

  @override
  Future<Map<String, dynamic>> create(
      {required String receiverId, required String amount, String? note}) async {
    creates++;
    this.receiverId = receiverId;
    this.amount = amount;
    return {'id': 'transfer-9', 'status': 'PENDING', 'fee': '0.03'};
  }
}

final class FakeTransferReference implements ChatTransferReferenceGateway {
  @override
  Future<void> sendReference(
      String transferId, String amount, String? note) async {}
}

final class FakeBalance implements ChatTransferBalanceSource {
  @override
  Future<double> balance() async => 500;
}

final class FakeContacts implements ChatTransferContactsSource {
  @override
  Future<List<ContactSummary>> contacts() async => [
        ContactSummary(
          userId: 'user-alice',
          username: 'alice',
          matrixUserId: '@alice:example.test',
          nickname: '爱丽丝',
        ),
        ContactSummary(
          userId: 'user-bob',
          username: 'bob',
          matrixUserId: '@bob:example.test',
          nickname: '鲍勃',
        ),
      ];
}

Future<void> _pump(WidgetTester tester,
    {String? peerId, String? peerName}) async {
  await tester.pumpWidget(CupertinoApp(
    home: ChatTransferSheet(
      controller: ChatTransferController(
        business: FakeTransferBusiness(),
        references: FakeTransferReference(),
      ),
      peerId: peerId,
      peerName: peerName,
      balanceSource: FakeBalance(),
      contactsSource: FakeContacts(),
      onSent: () {},
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('direct chat preselects the peer as recipient', (tester) async {
    await _pump(tester, peerId: 'user-bob', peerName: '鲍勃');
    expect(find.text('鲍勃'), findsOneWidget);
  });

  testWidgets('group chat requires picking a recipient before transfer',
      (tester) async {
    final business = FakeTransferBusiness();
    final sheet = ChatTransferSheet(
      controller: ChatTransferController(
        business: business,
        references: FakeTransferReference(),
      ),
      balanceSource: FakeBalance(),
      contactsSource: FakeContacts(),
      onSent: () {},
    );
    await tester.pumpWidget(CupertinoApp(home: sheet));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '5');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-transfer-error-dialog')),
        matching: find.text('请选择收款用户'),
      ),
      findsOneWidget,
    );
    expect(business.creates, 0);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-contact-user-alice')));
    await tester.pumpAndSettle();
    expect(find.text('爱丽丝'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-transfer-confirm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(business.creates, 1);
    expect(business.receiverId, 'user-alice');
    expect(business.amount, '5.00');
  });

  testWidgets('invalid amounts are rejected before the confirm dialog',
      (tester) async {
    final business = FakeTransferBusiness();
    final sheet = ChatTransferSheet(
      controller: ChatTransferController(
        business: business,
        references: FakeTransferReference(),
      ),
      peerId: 'user-bob',
      peerName: '鲍勃',
      balanceSource: FakeBalance(),
      contactsSource: FakeContacts(),
      onSent: () {},
    );
    await tester.pumpWidget(CupertinoApp(home: sheet));
    await tester.pump();

    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '0');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('chat-transfer-error-dialog')),
        matching: find.text('金额必须大于0'),
      ),
      findsOneWidget,
    );
    expect(business.creates, 0);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '2.005');
    expect(
      tester.widget<CupertinoTextField>(
        find.byKey(const Key('chat-transfer-amount')),
      ).controller!.text,
      '2.00',
      reason: '输入过滤器把小数限制到两位',
    );
  });
}
