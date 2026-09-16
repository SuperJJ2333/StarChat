import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_controller.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_sheet.dart';
import 'package:liuhetong_mobile/features/matrix/group_member_picker.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';

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
  String? lastReceiverId;
  String? lastReceiverMatrixId;
  @override
  Future<void> sendReference(
      String transferId, String amount, String? note,
      {String? receiverId, String? receiverMatrixId}) async {
    lastReceiverId = receiverId;
    lastReceiverMatrixId = receiverMatrixId;
  }
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
    final references = FakeTransferReference();
    final sheet = ChatTransferSheet(
      controller: ChatTransferController(
        business: business,
        references: references,
      ),
      balanceSource: FakeBalance(),
      isGroup: true,
      groupMembers: const [
        GroupMemberIdentity(
          matrixUserId: '@alice:example.test',
          displayName: '爱丽丝',
          businessUserId: 'user-alice',
        ),
      ],
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
    await tester.tap(
        find.byKey(const Key('chat-transfer-contact-@alice:example.test')));
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
    // 收款账号标识随引用消息进入房间：其他成员据此在本机解析「转给xx」。
    expect(references.lastReceiverId, 'user-alice');
    expect(references.lastReceiverMatrixId, '@alice:example.test');
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

  testWidgets('nonfriend group member resolves a verified business user ID before transfer', (tester) async {
    final business = FakeTransferBusiness();
    await tester.pumpWidget(CupertinoApp(home: ChatTransferSheet(
      controller: ChatTransferController(business: business, references: FakeTransferReference()),
      balanceSource: FakeBalance(), onSent: () {}, avatarMedia: _AvatarMedia(),
      isGroup: true,
      groupMembers: const [GroupMemberIdentity(matrixUserId: '@guest:test', displayName: '群成员')],
      resolveBusinessUser: (_) async => {'matrix_user_id': '@guest:test', 'user_id': 'user-guest'},
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-contact-@guest:test'))); await tester.pump(); await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '1');
    await tester.tap(find.byKey(const Key('chat-transfer-send'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action'))); await tester.pumpAndSettle();
    expect(business.receiverId, 'user-guest');
  });

  testWidgets('群聊收款人只能来自当前群成员，群成员未就绪时绝不回退通讯录',
      (tester) async {
    await tester.pumpWidget(CupertinoApp(
        home: ChatTransferSheet(
      controller: ChatTransferController(
        business: FakeTransferBusiness(),
        references: FakeTransferReference(),
      ),
      isGroup: true,
      balanceSource: FakeBalance(),
      contactsSource: FakeContacts(),
      onSent: () {},
    )));
    await tester.pump();

    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-transfer-contact-list')), findsNothing,
        reason: '群聊不得打开通讯录列表');
    expect(find.text('爱丽丝'), findsNothing, reason: '不得出现非本群成员');
    expect(find.text('鲍勃'), findsNothing, reason: '不得出现非本群成员');
    expect(find.text('群成员尚未加载，请稍后再试'), findsOneWidget);
  });

  testWidgets('私聊转账收款人固定为对方，不可更改', (tester) async {
    await _pump(tester, peerId: 'user-bob', peerName: '鲍勃');

    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('chat-transfer-contact-list')), findsNothing,
        reason: '私聊不得打开收款人选择');
    expect(find.text('爱丽丝'), findsNothing, reason: '私聊不得出现其他用户');
    expect(
        tester
            .widget<Text>(find.byKey(const Key('chat-transfer-recipient')))
            .data,
        '鲍勃',
        reason: '收款人必须保持为当前会话对方');
  });

  testWidgets('mismatched lookup cannot submit a Matrix ID as a transfer receiver', (tester) async {
    final business = FakeTransferBusiness();
    await tester.pumpWidget(CupertinoApp(home: ChatTransferSheet(
      controller: ChatTransferController(business: business, references: FakeTransferReference()),
      onSent: () {}, avatarMedia: _AvatarMedia(),
      isGroup: true,
      groupMembers: const [GroupMemberIdentity(matrixUserId: '@guest:test', displayName: '群成员')],
      resolveBusinessUser: (_) async => {'matrix_user_id': '@other:test', 'user_id': 'user-other'},
    )));
    await tester.tap(find.byKey(const Key('chat-transfer-recipient'))); await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-contact-@guest:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法确认收款账号'), findsOneWidget);
    expect(business.creates, 0);
  });
}

final class _AvatarMedia implements AvatarMediaCapability {
  @override Future<ResolvedAvatarUrl?> resolveAvatar({required Uri? avatarUri, required double size}) async => null;
}
