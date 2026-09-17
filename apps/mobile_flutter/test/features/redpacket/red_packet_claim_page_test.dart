import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'package:liuhetong_mobile/features/contacts/contact_models.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_page.dart';
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

final class _RefreshFailGateway implements RedPacketViewGateway {
  _RefreshFailGateway(this.delegate, this.shouldFail);
  final FakeRedPacketViewGateway delegate;
  final bool Function() shouldFail;
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    if (shouldFail()) throw StateError('detail unavailable');
    return delegate.redPacketDetail(id);
  }

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) =>
      delegate.claimRedPacket(id);
  @override
  Future<List<ContactSummary>> listContacts() => delegate.listContacts();
}

final class _SessionGateway
    implements RedPacketViewGateway, BusinessSessionMonitor {
  _SessionGateway(this.responses);
  final List<Object> responses;
  final invalidations =
      StreamController<BusinessSessionInvalidation>.broadcast(sync: true);
  var epoch = 1;
  var detailCalls = 0;
  var claimCalls = 0;
  @override
  int get sessionEpoch => epoch;
  @override
  Stream<BusinessSessionInvalidation> get sessionInvalidations =>
      invalidations.stream;
  @override
  Future<void> checkSessionValidity() async {}
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    final response = responses[detailCalls++];
    if (response is! Map<String, dynamic>) throw response;
    return response;
  }

  @override
  Future<Map<String, dynamic>> claimRedPacket(String id) async {
    claimCalls++;
    return {'amount': '8.88'};
  }

  @override
  Future<List<ContactSummary>> listContacts() async => const [];
  Future<void> close() => invalidations.close();
}

const _openDetail = {
  'id': 'packet-1',
  'sender_id': 'u-bob',
  'room_id': '!group:test',
  'total': '88.00',
  'share_count': 10,
  'claimed_count': 0,
  'status': 'OPEN',
  'claims': <Map<String, dynamic>>[],
};

const _privateOpenDetail = {
  'id': 'packet-2',
  'sender_id': 'u-bob',
  'room_id': null,
  'total': '88.00',
  'share_count': 1,
  'claimed_count': 0,
  'status': 'OPEN',
  'claims': <Map<String, dynamic>>[],
};

Future<void> _openPage(
  WidgetTester tester, {
  required RedPacketViewGateway gateway,
  VoidCallback? onClaimed,
}) async {
  await tester.pumpWidget(CupertinoApp(
      home: RedPacketClaimPage(
          api: gateway,
          packetId: 'packet-1',
          senderName: '项目小艾',
          onClaimed: onClaimed)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('红包封面整页进入：占满整屏并显示開', (tester) async {
    await _openPage(tester,
        gateway: FakeRedPacketViewGateway(detail: _openDetail));

    final page = find.byKey(const Key('red-packet-claim-page'));
    expect(page, findsOneWidget);
    expect(find.text('開'), findsOneWidget);
    expect(find.text('项目小艾的红包'), findsOneWidget);
    expect(find.text('看看大家的手气 >'), findsOneWidget);
    // 整页（不是居中弹窗卡片）：宽度铺满、高度远超弹窗卡片。
    final rect = tester.getRect(page);
    final appSize = tester.getSize(find.byType(CupertinoApp));
    expect(rect.width, closeTo(appSize.width, 1));
    expect(rect.height, greaterThan(appSize.height * 0.6));
  });

  testWidgets('整页红包页可用返回键退出', (tester) async {
    final gateway = FakeRedPacketViewGateway(detail: _openDetail);
    await tester.pumpWidget(CupertinoApp(
        home: Builder(
            builder: (context) => CupertinoButton(
                onPressed: () => Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                        builder: (_) => RedPacketClaimPage(
                            api: gateway, packetId: 'packet-1'))),
                child: const Text('打开红包')))));
    await tester.tap(find.text('打开红包'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('red-packet-claim-page')), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('red-packet-claim-page')), findsNothing);
  });

  testWidgets('私聊红包不显示看看大家的手气入口', (tester) async {
    await _openPage(tester,
        gateway: FakeRedPacketViewGateway(detail: _privateOpenDetail));
    expect(find.byKey(const Key('red-packet-claim-page')), findsOneWidget);
    expect(find.text('看看大家的手气 >'), findsNothing);
  });

  testWidgets('tapping 開 claims and shows the credited amount', (tester) async {
    final gateway = FakeRedPacketViewGateway(detail: _openDetail);
    await _openPage(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();

    expect(gateway.claimCalls, 1);
    expect(find.byKey(const Key('red-packet-claim-result')), findsOneWidget);
    expect(find.text('已领取 8.88 点钻，存入点钻余额'), findsOneWidget);
  });

  testWidgets('claim errors surface inline and keep the page open',
      (tester) async {
    final gateway = FakeRedPacketViewGateway(
      detail: _openDetail,
      claimError: Exception('手慢了，红包已被领完'),
    );
    await _openPage(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('手慢了，红包已被领完'), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-page')), findsOneWidget);
  });

  testWidgets('unknown status is not claimable', (tester) async {
    final gateway =
        FakeRedPacketViewGateway(detail: {..._openDetail}..remove('status'));
    await _openPage(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pump();
    expect(gateway.claimCalls, 0);
  });

  testWidgets('detail retry reloads instead of claiming', (tester) async {
    final gateway = _SessionGateway([StateError('offline'), _openDetail]);
    addTearDown(gateway.close);
    await _openPage(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    expect(gateway.detailCalls, 2);
    expect(gateway.claimCalls, 0);
    expect(find.text('開'), findsOneWidget);
  });

  testWidgets('session invalidation removes claimed amount and detail entry',
      (tester) async {
    final gateway = _SessionGateway([_openDetail]);
    addTearDown(gateway.close);
    await _openPage(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('8.88'), findsOneWidget);
    gateway.invalidations
        .add(const BusinessSessionInvalidation(epoch: 1, code: 'logout'));
    await tester.pump();
    expect(find.textContaining('8.88'), findsNothing);
    expect(find.byKey(const Key('red-packet-claim-luck-entry')), findsNothing);
    expect(find.text('会话已结束'), findsOneWidget);
  });

  testWidgets('epoch change without event prevents claim-detail navigation',
      (tester) async {
    final gateway = _SessionGateway([
      {
        ..._openDetail,
        'viewer_claim': {'amount': '8.88'}
      }
    ]);
    addTearDown(gateway.close);
    await _openPage(tester, gateway: gateway);
    gateway.epoch++;
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    expect(find.byType(RedPacketClaimDetailPage), findsNothing);
    expect(find.text('会话已结束'), findsOneWidget);
  });

  testWidgets('OPEN packet expired by trusted server time cannot claim',
      (tester) async {
    final gateway = FakeRedPacketViewGateway(detail: {
      ..._openDetail,
      'server_time': '2026-09-12T00:00:00Z',
      'expires_at': '2026-09-11T00:00:00Z',
    });
    await _openPage(tester, gateway: gateway);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pump();
    expect(gateway.claimCalls, 0);
  });

  testWidgets('COMPLETED without viewer claim says exhausted and cannot claim',
      (tester) async {
    final gateway = FakeRedPacketViewGateway(
        detail: {..._openDetail, 'status': 'COMPLETED'});
    await _openPage(tester, gateway: gateway);
    expect(find.text('已领完'), findsOneWidget);
    expect(find.text('已领取'), findsNothing);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pump();
    expect(gateway.claimCalls, 0);
  });

  testWidgets('EXPIRED without viewer claim says expired and cannot claim',
      (tester) async {
    final gateway =
        FakeRedPacketViewGateway(detail: {..._openDetail, 'status': 'EXPIRED'});
    await _openPage(tester, gateway: gateway);
    expect(find.text('已过期'), findsOneWidget);
    expect(find.text('已领取'), findsNothing);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pump();
    expect(gateway.claimCalls, 0);
  });

  testWidgets('claimed amount and callback survive detail refresh failure',
      (tester) async {
    var detailCalls = 0;
    var notified = 0;
    final gateway = FakeRedPacketViewGateway(detail: _openDetail);
    gateway.detail = _openDetail;
    await _openPage(tester,
        gateway: _RefreshFailGateway(gateway, () => ++detailCalls > 1),
        onClaimed: () => notified++);
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已领取 8.88 点钻'), findsOneWidget);
    expect(notified, 1);
    expect(find.textContaining('领取失败'), findsNothing);
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
    await _openPage(tester, gateway: gateway);

    await tester.tap(find.byKey(const Key('red-packet-claim-luck-entry')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const Key('red-packet-claim-detail-page')), findsOneWidget);
    expect(find.text('项目小艾的红包'), findsOneWidget);
  });
}
