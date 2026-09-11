import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_controller.dart';
import 'package:liuhetong_mobile/features/matrix/chat_red_packet_sheet.dart';

final class FakeRedPacketBusiness implements ChatRedPacketBusinessGateway {
  int creates = 0;
  String? recipientId;
  String? roomId;
  int? shareCount;
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
    this.roomId = roomId;
    this.recipientId = recipientId;
    this.shareCount = shareCount;
    final failure = error;
    if (failure != null) throw failure;
    return 'packet-1';
  }
}

final class FakeRedPacketReference implements ChatRedPacketReferenceGateway {
  int sends = 0;
  bool fail = true;

  @override
  Future<void> sendReference(String packetId, String greeting) async {
    sends++;
    if (fail) throw Exception('matrix unavailable');
  }
}

void main() {
  test('group count equal to the joined member total creates once', () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference()..fail = false,
      roomId: '!room:test',
      joinedMemberCount: 3,
      refreshJoinedMemberCount: () async => 3,
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 1);
    expect(business.shareCount, 3, reason: '成员总数包括发送者，刚好相等应允许创建');
  });

  test('group count above the joined member total does not create', () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
      joinedMemberCount: 2,
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 0);
    expect(controller.state.status, ChatRedPacketStatus.failed);
    expect(controller.state.message, '红包个数不能超过群成员人数');
  });

  test('fresh reduced membership rejects a count allowed by stale hint',
      () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
      joinedMemberCount: 10,
      refreshJoinedMemberCount: () async => 2,
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 0);
    expect(controller.state.message, '红包个数不能超过群成员人数');
  });

  test('fresh growth permits a count above the stale member hint', () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference()..fail = false,
      roomId: '!room:test',
      joinedMemberCount: 2,
      refreshJoinedMemberCount: () async => 3,
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 1);
  });

  test('held membership refresh makes repeated submits create once', () async {
    final business = FakeRedPacketBusiness();
    final membership = Completer<int>();
    var refreshes = 0;
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference()..fail = false,
      roomId: '!room:test',
      refreshJoinedMemberCount: () {
        refreshes++;
        return membership.future;
      },
    );

    final first =
        controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);
    final second =
        controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);
    expect(controller.state.status, ChatRedPacketStatus.creating);
    expect(refreshes, 1);
    membership.complete(3);
    await first;
    await second;

    expect(business.creates, 1);
    expect(refreshes, 1);
  });

  test('membership refresh failure does not create a packet', () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
      refreshJoinedMemberCount: () async => throw StateError('unavailable'),
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 0);
    expect(controller.state.message, '群成员加载失败，请稍后重试');
  });

  test('exclusive group packet rejects zero fresh joined members', () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
      refreshJoinedMemberCount: () async => 0,
    );

    await controller.submit(
      total: '3.00',
      greeting: '恭喜发财',
      mode: 'EXCLUSIVE',
      shareCount: 1,
      exclusiveRecipientId: 'user-bob',
    );

    expect(business.creates, 0);
    expect(controller.state.message, '红包个数不能超过群成员人数');
  });

  test('disposing during held membership refresh cannot create or notify',
      () async {
    final business = FakeRedPacketBusiness();
    final membership = Completer<int>();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
      refreshJoinedMemberCount: () => membership.future,
    );
    var notifications = 0;
    controller.addListener(() => notifications++);

    final submit =
        controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);
    expect(notifications, 1);
    controller.dispose();
    membership.complete(3);
    await submit;

    expect(business.creates, 0);
    expect(notifications, 1);
  });

  test('a submit requested after disposal cannot create a private packet',
      () async {
    final business = FakeRedPacketBusiness();
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      recipientId: 'user-bob',
    );
    controller.dispose();
    controller.dispose();

    await controller.submit(total: '3.00', greeting: '恭喜发财');

    expect(business.creates, 0);
  });

  test('server member-limit error maps to the group-count message', () async {
    final business = FakeRedPacketBusiness()
      ..error = BusinessApiException(
        statusCode: 422,
        code: 'RED_PACKET_SHARE_COUNT_EXCEEDS_MEMBERS',
        message: 'server detail',
      );
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference(),
      roomId: '!room:test',
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财', shareCount: 3);

    expect(business.creates, 1);
    expect(controller.state.message, '红包个数不能超过群成员人数');
  });

  test('private packet does not refresh group membership', () async {
    final business = FakeRedPacketBusiness();
    var refreshes = 0;
    final controller = ChatRedPacketController(
      business: business,
      references: FakeRedPacketReference()..fail = false,
      recipientId: 'user-bob',
      refreshJoinedMemberCount: () async {
        refreshes++;
        return 0;
      },
    );

    await controller.submit(total: '3.00', greeting: '恭喜发财');

    expect(refreshes, 0);
    expect(business.creates, 1);
  });

  test('share retry never creates a second authoritative red packet', () async {
    final business = FakeRedPacketBusiness();
    final references = FakeRedPacketReference();
    final controller = ChatRedPacketController(
      business: business,
      references: references,
      recipientId: 'user-bob',
    );

    await controller.submit(total: '8.88', greeting: '恭喜发财');
    expect(controller.state.status, ChatRedPacketStatus.shareFailed);
    expect(controller.state.packetId, 'packet-1');
    expect(business.creates, 1);
    expect(business.recipientId, 'user-bob');
    expect(business.roomId, isNull);

    references.fail = false;
    await controller.retryShare();

    expect(controller.state.status, ChatRedPacketStatus.sent);
    expect(business.creates, 1);
    expect(references.sends, 2);
  });

  testWidgets('direct chat red packet sheet creates and shares to the friend',
      (tester) async {
    final business = FakeRedPacketBusiness();
    final references = FakeRedPacketReference()..fail = false;
    final controller = ChatRedPacketController(
      business: business,
      references: references,
      recipientId: 'user-bob',
    );
    var sent = false;

    await tester.pumpWidget(
      CupertinoApp(
        home: ChatRedPacketSheet(
          controller: controller,
          isGroup: false,
          onSent: () => sent = true,
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('chat-red-packet-total')),
      '8.88',
    );
    await tester.enterText(
      find.byKey(const Key('chat-red-packet-greeting')),
      '恭喜发财',
    );
    await tester.tap(find.byKey(const Key('chat-red-packet-send')));
    await tester.pumpAndSettle();

    expect(sent, isTrue);
    expect(business.creates, 1);
    expect(find.text('红包已发送'), findsOneWidget);
  });
}
