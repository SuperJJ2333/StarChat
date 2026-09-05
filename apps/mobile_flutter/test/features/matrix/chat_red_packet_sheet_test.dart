import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_controller.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_sheet.dart';
import 'package:liuhetong_mobile/ui/foundation/wechat_tokens.dart';

final class FakeRedPacketBusiness implements ChatRedPacketBusinessGateway {
  int creates = 0;
  String? mode;
  String? total;
  int? shareCount;
  String? exclusiveRecipientId;
  Object? error;

  @override
  Future<String> create({
    required String mode,
    required String total,
    required int shareCount,
    String? roomId,
    String? recipientId,
  }) async {
    creates++;
    this.mode = mode;
    this.total = total;
    this.shareCount = shareCount;
    exclusiveRecipientId = recipientId;
    final failure = error;
    if (failure != null) throw failure;
    return 'packet-1';
  }
}

final class FakeRedPacketReference implements ChatRedPacketReferenceGateway {
  @override
  Future<void> sendReference(String packetId, String greeting) async {}
}

final class FakeSupport implements ChatRedPacketSupport {
  FakeSupport(this.balanceValue, this.maxTotalValue);
  final double balanceValue;
  final double maxTotalValue;
  @override
  Future<double> balance() async => balanceValue;
  @override
  Future<RedPacketLimits> limits() async =>
      RedPacketLimits(maxTotal: maxTotalValue);
}

Future<void> _pump(
  WidgetTester tester, {
  required ChatRedPacketController controller,
  ChatRedPacketSupport? support,
  bool isGroup = false,
  List<ChatRoomMember> members = const <ChatRoomMember>[],
}) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: ChatRedPacketSheet(
        controller: controller,
        isGroup: isGroup,
        support: support,
        members: members,
        onSent: () {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets(
      'send page shows wechat-style labeled rows with right aligned numeric input',
      (tester) async {
    final controller = ChatRedPacketController(
      business: FakeRedPacketBusiness(),
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    await _pump(tester, controller: controller);

    expect(find.text('总金额'), findsOneWidget);
    expect(find.text('祝福语'), findsOneWidget);
    expect(find.text('塞钱进红包'), findsOneWidget);
    expect(find.text('单个红包金额不可超过 20000.00 点钻'), findsOneWidget);
    expect(find.text('未领取的红包，将于24小时后发起退款'), findsOneWidget);
    final totalField = tester.widget<CupertinoTextField>(
      find.byKey(const Key('chat-red-packet-total')),
    );
    expect(totalField.textAlign, TextAlign.right);
    expect(
      totalField.keyboardType,
      const TextInputType.numberWithOptions(decimal: true),
    );
  });

  testWidgets(
      'group page offers three red packet types and a share count field',
      (tester) async {
    final controller = ChatRedPacketController(
      business: FakeRedPacketBusiness(),
      references: FakeRedPacketReference(),
      roomId: '!room:test',
    );
    await _pump(tester, controller: controller, isGroup: true);

    expect(find.text('拼手气红包'), findsOneWidget);
    expect(find.text('红包个数'), findsOneWidget);
    final sharesField = tester.widget<CupertinoTextField>(
      find.byKey(const Key('chat-red-packet-shares')),
    );
    expect(sharesField.textAlign, TextAlign.right);
    expect(sharesField.keyboardType, TextInputType.number);
  });

  testWidgets(
      'amount above the fetched limit is rejected with a popup before charging',
      (tester) async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    await _pump(
      tester,
      controller: controller,
      support: FakeSupport(100, 200),
    );

    await tester.enterText(
        find.byKey(const Key('chat-red-packet-total')), '300');
    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();

    expect(find.text('单个红包金额不能超过 200.00 点钻'), findsOneWidget);
    expect(business.creates, 0);
  });

  testWidgets('amount above balance pops the exact insufficient message',
      (tester) async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    await _pump(
      tester,
      controller: controller,
      support: FakeSupport(1.00, 20000),
    );

    await tester.enterText(
        find.byKey(const Key('chat-red-packet-total')), '5.00');
    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();

    expect(
      find.text('红包创建失败，账户余额不足'),
      findsOneWidget,
      reason: '余额不足时必须弹出指定提示文案',
    );
    expect(
      find.byKey(const Key('chat-red-packet-insufficient-dialog')),
      findsOneWidget,
    );
    expect(business.creates, 0);
  });

  testWidgets('server insufficient balance error pops the same message',
      (tester) async {
    final business = FakeRedPacketBusiness()
      ..error = BusinessApiException(
        statusCode: 422,
        code: 'RED_PACKET_BALANCE_INSUFFICIENT',
        message: '红包创建失败，账户余额不足',
      );
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    await _pump(
      tester,
      controller: controller,
      support: FakeSupport(500, 20000),
    );

    await tester.enterText(
        find.byKey(const Key('chat-red-packet-total')), '5.00');
    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();

    expect(find.text('红包创建失败，账户余额不足'), findsOneWidget);
    expect(business.creates, 1);
  });

  testWidgets('exclusive red packet requires picking a group member',
      (tester) async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
    );
    await _pump(
      tester,
      controller: controller,
      isGroup: true,
      members: const [ChatRoomMember('user-alice', '爱丽丝')],
    );

    await tester.enterText(
        find.byKey(const Key('chat-red-packet-total')), '8.88');
    await tester.tap(find.byKey(const Key('chat-red-packet-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('专属红包').last);
    await tester.pumpAndSettle();
    expect(find.text('指定成员'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();
    expect(find.text('请选择专属红包接收人'), findsOneWidget);
    expect(business.creates, 0);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('chat-red-packet-recipient')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('chat-red-packet-member-user-alice')));
    await tester.pumpAndSettle();
    expect(find.text('爱丽丝'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();
    expect(business.creates, 1);
    expect(business.mode, 'EXCLUSIVE');
    expect(business.exclusiveRecipientId, 'user-alice');
    expect(business.shareCount, 1);
  });

  testWidgets('page uses the wechat red packet gradient background',
      (tester) async {
    final controller = ChatRedPacketController(
      business: FakeRedPacketBusiness(),
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    await _pump(tester, controller: controller);

    final gradientContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('塞钱进红包'),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = gradientContainer.decoration! as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors.first, WeChatColors.redPacketCreateGradientTop);
    expect(gradient.colors.last, WeChatColors.redPacketCreateGradientBottom);
  });
}
