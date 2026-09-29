import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_controller.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_sheet.dart';
import 'package:liuhetong_mobile/features/matrix/group_member_picker.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_user_avatar.dart';
import 'package:liuhetong_mobile/features/matrix/avatar_url_resolver.dart';
import 'package:liuhetong_mobile/ui/components/user_avatar.dart';
import 'package:liuhetong_mobile/ui/foundation/avatar_cache.dart';

import '../wallet/manual_wallet_api_test.dart' as fixtures;

final class FakeTransferBusiness implements ChatTransferBusinessGateway {
  int creates = 0;
  String? receiverId;
  String? amount;

  @override
  Future<Map<String, dynamic>> create(
      {required String receiverId,
      required String amount,
      String? note}) async {
    creates++;
    this.receiverId = receiverId;
    this.amount = amount;
    return {'id': 'transfer-9', 'status': 'PENDING', 'fee': '0.03'};
  }
}

final class _PendingTransferBusiness implements ChatTransferBusinessGateway {
  final result = Completer<Map<String, dynamic>>();
  int creates = 0;

  @override
  Future<Map<String, dynamic>> create(
      {required String receiverId, required String amount, String? note}) {
    creates++;
    return result.future;
  }
}

final class FakeTransferReference implements ChatTransferReferenceGateway {
  String? lastReceiverId;
  String? lastReceiverMatrixId;
  @override
  Future<void> sendReference(String transferId, String amount, String? note,
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

final class _AvatarContacts implements ChatTransferContactsSource {
  const _AvatarContacts(this.url);
  final String url;

  @override
  Future<List<ContactSummary>> contacts() async => [
        ContactSummary(
            userId: 'shared-recipient',
            username: 'shared',
            matrixUserId: '@shared:test',
            avatarUrl: url),
      ];
}

final class _DelayedContacts implements ChatTransferContactsSource {
  final response = Completer<List<ContactSummary>>();

  @override
  Future<List<ContactSummary>> contacts() => response.future;
}

Future<BusinessApiClient> _avatarApi(String matrixUserId,
    {Future<http.Response> Function(http.Request)? responder}) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test',
      refreshToken: 'refresh',
      matrixUserId: matrixUserId);
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient(responder ??
          (_) async => http.Response(jsonEncode({'balance': '500.00'}), 200,
              headers: {'content-type': 'application/json'})));
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
  testWidgets('stale account A confirmation cannot submit account B transfer',
      (tester) async {
    final apiA = await _avatarApi('@confirm-account-a:test');
    final apiB = await _avatarApi('@confirm-account-b:test');
    final businessA = FakeTransferBusiness();
    final businessB = FakeTransferBusiness();
    final controllerA = ChatTransferController(
        business: businessA, references: FakeTransferReference());
    final controllerB = ChatTransferController(
        business: businessB, references: FakeTransferReference());
    Widget sheet(BusinessApiClient api, ChatTransferController controller,
            String peerId, String peerName) =>
        CupertinoApp(
            home: ChatTransferSheet(
          controller: controller,
          peerId: peerId,
          peerName: peerName,
          balanceSource: BusinessChatTransferBalanceSource(api),
          onSent: () {},
        ));

    await tester
        .pumpWidget(sheet(apiA, controllerA, 'recipient-a', 'Account A'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '7');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Account A'), findsWidgets);

    await tester
        .pumpWidget(sheet(apiB, controllerB, 'recipient-b', 'Account B'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(businessA.creates, 0);
    expect(businessB.creates, 0,
        reason: 'A confirmation must not authorize a B transfer');

    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(businessB.creates, 1);
    expect(businessB.receiverId, 'recipient-b');
    await tester.pumpWidget(const SizedBox());
    controllerA.dispose();
    controllerB.dispose();
  });

  testWidgets(
      'session epoch rotation invalidates an open transfer confirmation',
      (tester) async {
    final api = await _avatarApi('@confirm-epoch:test');
    final business = FakeTransferBusiness();
    final controller = ChatTransferController(
        business: business, references: FakeTransferReference());
    await tester.pumpWidget(CupertinoApp(
        home: ChatTransferSheet(
      controller: controller,
      peerId: 'recipient',
      peerName: 'Recipient',
      balanceSource: BusinessChatTransferBalanceSource(api),
      onSent: () {},
    )));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '2');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    final priorEpoch = api.sessionEpoch;
    await api.clearLocalSession();
    expect(api.sessionEpoch, greaterThan(priorEpoch));

    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(business.creates, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('A to B to A cannot revive the original confirmation',
      (tester) async {
    final apiA = await _avatarApi('@aba-account-a:test');
    final apiB = await _avatarApi('@aba-account-b:test');
    final business = FakeTransferBusiness();
    final controller = ChatTransferController(
        business: business, references: FakeTransferReference());
    Widget sheet(BusinessApiClient api, String peerId) => CupertinoApp(
            home: ChatTransferSheet(
          controller: controller,
          peerId: peerId,
          peerName: peerId,
          balanceSource: BusinessChatTransferBalanceSource(api),
          onSent: () {},
        ));

    await tester.pumpWidget(sheet(apiA, 'same-recipient'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '4');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('chat-transfer-confirm-dialog')), findsOneWidget);

    await tester.pumpWidget(sheet(apiB, 'other-recipient'));
    await tester.pump();
    await tester.pumpWidget(sheet(apiA, 'same-recipient'));
    await tester.pump();
    expect(
        find.byKey(const Key('chat-transfer-confirm-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();

    expect(business.creates, 0,
        reason: 'returning to identical values cannot revive an A lease');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('completed A transfer cannot call B success after account swap',
      (tester) async {
    final apiA = await _avatarApi('@pending-account-a:test');
    final apiB = await _avatarApi('@pending-account-b:test');
    final businessA = _PendingTransferBusiness();
    final businessB = FakeTransferBusiness();
    final controllerA = ChatTransferController(
        business: businessA, references: FakeTransferReference());
    final controllerB = ChatTransferController(
        business: businessB, references: FakeTransferReference());
    var sentA = 0;
    var sentB = 0;
    Widget sheet(BusinessApiClient api, ChatTransferController controller,
            VoidCallback onSent) =>
        CupertinoApp(
            home: ChatTransferSheet(
          controller: controller,
          peerId: 'same-recipient',
          peerName: 'Recipient',
          balanceSource: BusinessChatTransferBalanceSource(api),
          onSent: onSent,
        ));

    await tester.pumpWidget(sheet(apiA, controllerA, () => sentA++));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '3');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pump();
    expect(businessA.creates, 1);

    controllerB.state =
        const ChatTransferState(status: ChatTransferStatus.sent);
    await tester.pumpWidget(sheet(apiB, controllerB, () => sentB++));
    await tester.pump();
    businessA.result.complete({'id': 'old-transfer', 'status': 'PENDING'});
    await tester.pumpAndSettle();
    expect(sentA, 0);
    expect(sentB, 0,
        reason: 'old account completion must not navigate the new account');
    expect(businessB.creates, 0);
    await tester.pumpWidget(const SizedBox());
    controllerA.dispose();
    controllerB.dispose();
  });

  testWidgets('group picker closes on the first account B frame',
      (tester) async {
    final apiA = await _avatarApi('@account-a:test');
    final apiB = await _avatarApi('@account-b:test');
    final business = FakeTransferBusiness();
    final controller = ChatTransferController(
        business: business, references: FakeTransferReference());
    const aMember = GroupMemberIdentity(
        matrixUserId: '@account-a-member:test',
        displayName: 'Account A Member',
        businessUserId: 'a-receiver',
        businessAvatarUrl: 'https://media.example.test/a-avatar?v=1');
    const bMember = GroupMemberIdentity(
        matrixUserId: '@account-b-member:test',
        displayName: 'Account B Member',
        businessUserId: 'b-receiver');

    Widget sheet(
            BusinessApiClient api, GroupMemberIdentity member) =>
        CupertinoApp(
            home: ChatTransferSheet(
                controller: controller,
                isGroup: true,
                groupMembers: [member],
                balanceSource: BusinessChatTransferBalanceSource(api),
                onSent: () {}));
    await tester.pumpWidget(sheet(apiA, aMember));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    expect(find.text('Account A Member'), findsWidgets);

    await tester.pumpWidget(sheet(apiB, bMember));
    expect(find.text('Account A Member'), findsNothing);
    expect(
        tester
            .widgetList<UserAvatar>(find.byType(UserAvatar))
            .where((avatar) => avatar.avatarUrl?.contains('a-avatar') == true),
        isEmpty,
        reason: 'the account A avatar URL must leave the first B frame');
    expect(
        find.byKey(const Key('chat-transfer-contact-@account-a-member:test')),
        findsNothing);
    expect(find.byType(GroupMemberAvatar), findsNothing,
        reason: 'account A group avatar must not become B recipient');
    expect(find.text('请选择收款用户'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '1');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(find.text('请选择收款用户'), findsWidgets);
    expect(business.creates, 0,
        reason: 'account A recipient ID must not be submitted by account B');
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const Key('chat-transfer-contact-@account-b-member:test')));
    await tester.pumpAndSettle();
    expect(find.text('Account B Member'), findsOneWidget);
    expect(find.byType(GroupMemberAvatar), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(business.receiverId, 'b-receiver');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('group picker closes on the first session epoch frame',
      (tester) async {
    final api = await _avatarApi('@account-a:test');
    final controller = ChatTransferController(
        business: FakeTransferBusiness(), references: FakeTransferReference());
    Widget sheet() => CupertinoApp(
          home: ChatTransferSheet(
            controller: controller,
            isGroup: true,
            groupMembers: const [
              GroupMemberIdentity(
                matrixUserId: '@account-a-member:test',
                displayName: 'Account A Member',
                businessUserId: 'a-receiver',
                businessAvatarUrl: 'https://media.example.test/a-avatar?v=1',
              ),
            ],
            balanceSource: BusinessChatTransferBalanceSource(api),
            onSent: () {},
          ),
        );
    await tester.pumpWidget(sheet());
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    expect(find.text('Account A Member'), findsWidgets);

    final previousEpoch = api.sessionEpoch;
    await api.clearLocalSession();
    expect(api.sessionEpoch, greaterThan(previousEpoch));
    await tester.pumpWidget(sheet());
    expect(find.text('Account A Member'), findsNothing);
    expect(
        tester
            .widgetList<UserAvatar>(find.byType(UserAvatar))
            .where((avatar) => avatar.avatarUrl?.contains('a-avatar') == true),
        isEmpty);
    expect(find.byType(GroupMemberPicker), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('group member avatar cache is scoped across accounts',
      (tester) async {
    final apiA = await _avatarApi('@account-a:test');
    final apiB = await _avatarApi('@account-b:test');
    final controller = ChatTransferController(
        business: FakeTransferBusiness(), references: FakeTransferReference());
    Widget sheet(BusinessApiClient api, String avatarUrl) => CupertinoApp(
          home: ChatTransferSheet(
            controller: controller,
            isGroup: true,
            groupMembers: [
              GroupMemberIdentity(
                matrixUserId: '@shared-member:test',
                displayName: 'Shared Member',
                businessUserId: 'group-shared-recipient-2191',
                businessAvatarUrl: avatarUrl,
              ),
            ],
            balanceSource: BusinessChatTransferBalanceSource(api),
            onSent: () {},
          ),
        );

    await tester.pumpWidget(
        sheet(apiA, 'https://media.example.test/shared-avatar?token=a&v=1'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    final accountAAvatar = tester.widget<UserAvatar>(find.descendant(
        of: find.byType(GroupMemberPicker), matching: find.byType(UserAvatar)));
    final accountAImage = tester.widget<Image>(find.byType(Image).first);
    accountAImage.frameBuilder!(
        tester.element(find.byType(Image).first), const SizedBox(), 0, true);
    final retainedA = AvatarCache.lastSuccessful(
        accountAAvatar.avatarCacheKey ?? accountAAvatar.fallbackSeed);
    expect(retainedA, isNotNull);

    await tester.pumpWidget(
        sheet(apiB, 'https://media.example.test/shared-avatar?token=b&v=1'));
    expect(find.byType(GroupMemberPicker), findsNothing);
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    final accountBAvatar = tester.widget<UserAvatar>(find.descendant(
        of: find.byType(GroupMemberPicker), matching: find.byType(UserAvatar)));
    final accountBImage = tester.widget<Image>(find.byType(Image).first);
    expect(
        accountBImage.frameBuilder!(tester.element(find.byType(Image).first),
            const SizedBox(), null, false),
        isNot(isA<Stack>()),
        reason: 'B must not paint A retained provider while its URL loads');
    expect(accountBAvatar.avatarCacheKey, isNotNull);
    expect(accountBAvatar.avatarCacheKey, isNot(accountAAvatar.avatarCacheKey));
    expect(AvatarCache.lastSuccessful(accountAAvatar.avatarCacheKey!),
        same(retainedA));

    await tester.tap(
        find.byKey(const Key('chat-transfer-contact-@shared-member:test')));
    await tester.pumpAndSettle();
    final selectedAvatar = tester.widget<UserAvatar>(find.descendant(
        of: find.byType(GroupMemberAvatar), matching: find.byType(UserAvatar)));
    expect(selectedAvatar.avatarCacheKey, accountBAvatar.avatarCacheKey);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
      'late account A contacts cannot open under account B avatar scope',
      (tester) async {
    final delayedBalanceA = Completer<http.Response>();
    final apiA = await _avatarApi('@account-a:test',
        responder: (_) => delayedBalanceA.future);
    final apiB = await _avatarApi('@account-b:test',
        responder: (_) async => http.Response(
            jsonEncode({'balance': '5.00'}), 200,
            headers: {'content-type': 'application/json'}));
    final delayedA = _DelayedContacts();
    final contactsB = _DelayedContacts();
    final controller = ChatTransferController(
        business: FakeTransferBusiness(), references: FakeTransferReference());

    Widget sheet(BusinessApiClient api, ChatTransferContactsSource contacts) =>
        CupertinoApp(
            home: ChatTransferSheet(
                controller: controller,
                balanceSource: BusinessChatTransferBalanceSource(api),
                contactsSource: contacts,
                onSent: () {}));
    await tester.pumpWidget(sheet(apiA, delayedA));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pump();
    expect(delayedA.response.isCompleted, isFalse);

    await tester.pumpWidget(sheet(apiB, contactsB));
    await tester.pump();
    delayedA.response.complete(const [
      ContactSummary(
          userId: 'account-a-only',
          username: 'account-a',
          matrixUserId: '@account-a-contact:test',
          nickname: 'Account A Contact',
          avatarUrl: 'https://media.example.test/a?v=1'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Account A Contact'), findsNothing);
    expect(find.byKey(const Key('chat-transfer-contact-account-a-only')),
        findsNothing);
    expect(find.byKey(const Key('chat-transfer-contact-list')), findsNothing,
        reason: 'a stale response must not open a picker under account B');
    expect(find.textContaining('余额 5.00'), findsOneWidget);
    delayedBalanceA.complete(http.Response(
        jsonEncode({'balance': '999.00'}), 200,
        headers: {'content-type': 'application/json'}));
    await tester.pumpAndSettle();
    expect(find.textContaining('余额 5.00'), findsOneWidget,
        reason: 'a late A balance must not replace the B balance');
    expect(find.textContaining('余额 999.00'), findsNothing);

    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pump();
    contactsB.response.complete(const [
      ContactSummary(
          userId: 'account-b-only',
          username: 'account-b',
          matrixUserId: '@account-b-contact:test',
          nickname: 'Account B Contact',
          avatarUrl: 'https://media.example.test/b?v=1'),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Account B Contact'), findsOneWidget);
    expect(find.byKey(const Key('chat-transfer-contact-account-b-only')),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('transfer avatars do not retain the previous account during load',
      (tester) async {
    final apiA = await _avatarApi('@account-a:test');
    final apiB = await _avatarApi('@account-b:test');
    final controllerA = ChatTransferController(
        business: FakeTransferBusiness(), references: FakeTransferReference());
    final controllerB = ChatTransferController(
        business: FakeTransferBusiness(), references: FakeTransferReference());

    await tester.pumpWidget(CupertinoApp(
        key: const ValueKey('transfer-account-a'),
        home: ChatTransferSheet(
            controller: controllerA,
            peerId: 'shared-recipient',
            peerName: 'Shared',
            peerAvatarUrl: 'https://media.example.test/avatar?token=a&v=1',
            balanceSource: BusinessChatTransferBalanceSource(apiA),
            onSent: () {})));
    await tester.pump();
    final accountAAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(accountAAvatar.avatarCacheKey, isNotNull);
    final accountAImage = tester.widget<Image>(find.byType(Image).first);
    accountAImage.frameBuilder!(
        tester.element(find.byType(Image).first), const SizedBox(), 0, true);
    final retained = AvatarCache.lastSuccessful(accountAAvatar.avatarCacheKey!);
    expect(retained, isNotNull);

    await tester.pumpWidget(CupertinoApp(
        key: const ValueKey('transfer-account-b'),
        home: ChatTransferSheet(
            controller: controllerB,
            balanceSource: BusinessChatTransferBalanceSource(apiB),
            contactsSource: const _AvatarContacts(
                'https://media.example.test/avatar?token=b&v=1'),
            onSent: () {})));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    final accountBPickerAvatar =
        tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(accountBPickerAvatar.avatarCacheKey,
        isNot(accountAAvatar.avatarCacheKey));
    final accountBImage = tester.widget<Image>(find.byType(Image).first);
    expect(
        accountBImage.frameBuilder!(tester.element(find.byType(Image).first),
            const SizedBox(), null, false),
        isNot(isA<Stack>()),
        reason: 'the pending account B image cannot paint account A provider');
    expect(AvatarCache.lastSuccessful(accountAAvatar.avatarCacheKey!),
        same(retained));

    await tester
        .tap(find.byKey(const Key('chat-transfer-contact-shared-recipient')));
    await tester.pumpAndSettle();
    final selectedAvatar = tester.widget<UserAvatar>(find.byType(UserAvatar));
    expect(selectedAvatar.avatarCacheKey, accountBPickerAvatar.avatarCacheKey);
    await tester.pumpWidget(const SizedBox());
    controllerA.dispose();
    controllerB.dispose();
  });

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
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatTransferSheet), findsOneWidget);
    expect(find.byType(GroupMemberPicker), findsNothing);
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const Key('chat-transfer-contact-@alice:example.test')));
    await tester.pumpAndSettle();
    expect(find.text('爱丽丝'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('chat-transfer-confirm-dialog')), findsOneWidget);
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

    await tester.enterText(
        find.byKey(const Key('chat-transfer-amount')), '2.005');
    expect(
      tester
          .widget<CupertinoTextField>(
            find.byKey(const Key('chat-transfer-amount')),
          )
          .controller!
          .text,
      '2.00',
      reason: '输入过滤器把小数限制到两位',
    );
  });

  testWidgets(
      'nonfriend group member resolves a verified business user ID before transfer',
      (tester) async {
    final business = FakeTransferBusiness();
    await tester.pumpWidget(CupertinoApp(
        home: ChatTransferSheet(
      controller: ChatTransferController(
          business: business, references: FakeTransferReference()),
      balanceSource: FakeBalance(),
      onSent: () {},
      avatarMedia: _AvatarMedia(),
      isGroup: true,
      groupMembers: const [
        GroupMemberIdentity(matrixUserId: '@guest:test', displayName: '群成员')
      ],
      resolveBusinessUser: (_) async =>
          {'matrix_user_id': '@guest:test', 'user_id': 'user-guest'},
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('chat-transfer-contact-@guest:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byKey(const Key('chat-transfer-amount')), '1');
    await tester.tap(find.byKey(const Key('chat-transfer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-confirm-action')));
    await tester.pumpAndSettle();
    expect(business.receiverId, 'user-guest');
  });

  testWidgets('群聊收款人只能来自当前群成员，群成员未就绪时绝不回退通讯录', (tester) async {
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

  testWidgets(
      'mismatched lookup cannot submit a Matrix ID as a transfer receiver',
      (tester) async {
    final business = FakeTransferBusiness();
    await tester.pumpWidget(CupertinoApp(
        home: ChatTransferSheet(
      controller: ChatTransferController(
          business: business, references: FakeTransferReference()),
      onSent: () {},
      avatarMedia: _AvatarMedia(),
      isGroup: true,
      groupMembers: const [
        GroupMemberIdentity(matrixUserId: '@guest:test', displayName: '群成员')
      ],
      resolveBusinessUser: (_) async =>
          {'matrix_user_id': '@other:test', 'user_id': 'user-other'},
    )));
    await tester.tap(find.byKey(const Key('chat-transfer-recipient')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('chat-transfer-contact-@guest:test')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('无法确认收款账号'), findsOneWidget);
    expect(business.creates, 0);
  });
}

final class _AvatarMedia implements AvatarMediaCapability {
  @override
  Future<ResolvedAvatarUrl?> resolveAvatar(
          {required Uri? avatarUri, required double size}) async =>
      null;
}
