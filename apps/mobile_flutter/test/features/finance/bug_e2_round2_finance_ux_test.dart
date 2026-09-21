import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_presentation.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_entry.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_dialog.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_sheet.dart';
import 'package:liuhetong_mobile/ui/finance/wechat_red_packet_card.dart';

/// E2 二轮：微信式领取体验。
/// - 暖缓存点击**立即**打开弹层/详情（不再先等一轮强制明细请求）；
/// - 领取/收款成功后气泡**立即**翻转（乐观补丁），不等后台确认刷新；
/// - 多红包并发：各 key 缓存互不串扰。

Future<BusinessApiClient> _api(
  Future<http.Response> Function(http.Request request) handler,
) async {
  final session = SecureSessionStore(_MemoryStore());
  await session.saveSession(
    accessToken: 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJyZWNlaXZlci0xIn0.sig',
    refreshToken: 'refresh',
  );
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: session,
    client: MockClient(handler),
  );
}

http.Response _json(Map<String, dynamic> value) => http.Response(
      jsonEncode(value),
      200,
      headers: const {'content-type': 'application/json'},
    );

Map<String, dynamic> _packet({Object? viewerClaim}) => {
      'id': 'packet-1',
      'status': 'OPEN',
      'amount': '8.88',
      'viewer_claim': viewerClaim,
      'room_id': 'room-1',
      'server_time': '2026-09-11T10:00:00Z',
      'expires_at': '2026-09-11T11:00:00Z',
    };

Map<String, dynamic> _transfer({String status = 'PENDING'}) => {
      'id': 'transfer-1',
      'status': status,
      'sender_id': 'sender-1',
      'receiver_id': 'receiver-1',
      'amount': '8.88',
      'created_at': '2026-09-11T10:00:00Z',
    };

Future<void> _pumpEntry(
  WidgetTester tester, {
  required FinanceCardStore store,
  required BusinessApiClient api,
  required FinanceCardKind kind,
  required String id,
}) =>
    tester.pumpWidget(CupertinoApp(
      home: FinanceMessageEntry(
        store: store,
        api: api,
        kind: kind,
        id: id,
        greeting: '恭喜发财',
        amount: '8.88',
        isOwn: false,
        senderName: '发送者',
      ),
    ));

final class _MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<void> delete(String key) async => _values.remove(key);
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

void main() {
  testWidgets('E2-B：暖缓存的可领红包点击即开弹层（明细请求在途也立即打开）',
      (tester) async {
    final held = Completer<http.Response>();
    var reads = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        reads++;
        return reads == 1
            ? _json(_packet())
            : held.future; // 弹层自身的明细请求保持挂起
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    // 预热：第一次进入会话完成一次明细缓存。
    final warm = store.lease(const FinanceCardKey.redPacket('packet-1'));
    warm.setVisible(true);
    await warm.ensureFresh();
    warm.setVisible(false);
    warm.dispose();
    expect(reads, 1);

    // 重新进入会话（新的卡片实例），tap 时不等在途请求。
    await _pumpEntry(tester,
        store: store, api: api, kind: FinanceCardKind.redPacket, id: 'packet-1');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pump();
    await tester.pump();

    expect(find.byType(RedPacketClaimDialog), findsOneWidget,
        reason: '暖缓存必须立即打开领取弹层，不得先等强制明细往返（领取卡顿根因）');
    held.complete(_json(_packet()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('E2-B：暖缓存的已领红包点击直达详情页', (tester) async {
    final held = Completer<http.Response>();
    var reads = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        reads++;
        return reads == 1
            ? _json(_packet(viewerClaim: {'amount': '8.88'}))
            : held.future;
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);
    final warm = store.lease(const FinanceCardKey.redPacket('packet-1'));
    warm.setVisible(true);
    await warm.ensureFresh();
    warm.setVisible(false);
    warm.dispose();

    await _pumpEntry(tester,
        store: store, api: api, kind: FinanceCardKind.redPacket, id: 'packet-1');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(RedPacketClaimDetailPage), findsOneWidget,
        reason: '已领取的红包必须直达详情页，无需预取');
    held.complete(_json(_packet(viewerClaim: {'amount': '8.88'})));
    await tester.pumpAndSettle();
  });

  testWidgets('E2-B：暖缓存的转账点击直达详情面板', (tester) async {
    final held = Completer<http.Response>();
    var reads = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/chat-transfers/transfer-1') {
        reads++;
        return reads == 1 ? _json(_transfer()) : held.future;
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);
    final warm = store.lease(const FinanceCardKey.transfer('transfer-1'));
    warm.setVisible(true);
    await warm.ensureFresh();
    warm.setVisible(false);
    warm.dispose();

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.transfer,
        id: 'transfer-1');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChatTransferDetailSheet), findsOneWidget,
        reason: '暖缓存的转账必须立即打开详情面板');
    held.complete(_json(_transfer()));
    await tester.pumpAndSettle();
  });

  testWidgets('E2-C：领取成功后气泡立即翻转「已领取」（不等确认刷新）',
      (tester) async {
    var claimed = false;
    final refetchHeld = Completer<http.Response>();
    var reads = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        reads++;
        if (reads == 1) return _json(_packet());
        if (claimed) {
          // 领取后的权威确认刷新保持挂起——卡片必须先靠乐观补丁翻转。
          return refetchHeld.future;
        }
        return _json(_packet());
      }
      if (request.url.path == '/api/v1/red-packets/packet-1/claims') {
        claimed = true;
        return _json({'amount': '8.88'});
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store, api: api, kind: FinanceCardKind.redPacket, id: 'packet-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    // 领取成功 → 弹窗关闭并进入领取详情页。
    expect(find.byType(RedPacketClaimDetailPage), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.pump();
    expect(refetchHeld.isCompleted, isFalse, reason: '确认刷新仍在途');
    expect(find.byType(WeChatRedPacketCard), findsOneWidget);
    expect(find.text('已领取'), findsOneWidget,
        reason: '乐观补丁必须让气泡立即翻转，不等确认刷新');

    refetchHeld.complete(_json(_packet(viewerClaim: {'amount': '8.88'})));
    await tester.pumpAndSettle();
  });

  
testWidgets('E2-F2：自己发的红包被领完后，用户点击卡片才刷新为「已领完」',
    (tester) async {
  var completed = false;
  final gateway = _GatedGateway((id) {
    final status = completed ? 'COMPLETED' : 'OPEN';
    return Future.value({
      'id': id,
      'status': status,
      'amount': '8.88',
      'viewer_claim': null,
      'sender_id': 'receiver-1',
      'server_time': '2026-09-11T10:00:00Z',
      'expires_at': '2026-09-11T11:00:00Z',
    });
  });
  final store = FinanceCardStore(gateway);
  addTearDown(store.dispose);

  final lease = store.lease(const FinanceCardKey.redPacket('packet-9'));
  lease.setVisible(true);
  await lease.ensureFresh();
  expect(redPacketVisualState(lease.notifier.value.detail),
      RedPacketVisualState.available);
  expect(lease.notifier.value.terminal, isFalse);

  // 长时间停留不再周期轮询（E2-F4 用户指令）。
  await tester.pump(const Duration(seconds: 31));
  expect(gateway.detailCalls, 1, reason: '无轮询：停留不产生新的拉取');

  // 用户点击卡片（open 流程）→ 强制刷新 → 已领完翻转 + 终态。
  completed = true;
  await lease.ensureFresh(force: true);
  expect(lease.notifier.value.detail?['status'], 'COMPLETED');
  expect(lease.notifier.value.terminal, isTrue);
  expect(redPacketVisualState(lease.notifier.value.detail),
      RedPacketVisualState.exhausted, reason: '封面切换为「已领完」');
  lease.setVisible(false);
  lease.dispose();
});

test('E2-D：多红包并发缓存互不串扰、补丁只影响自身', () async {
    final gates = <String, Completer<http.Response>>{};
    final counts = <String, int>{};
    final gateway = _FakeGateway((request) async {
      final match = RegExp(r'/api/v1/red-packets/(packet-\d)$')
          .firstMatch(request.url.path);
      if (match != null) {
        final id = match.group(1)!;
        counts[id] = (counts[id] ?? 0) + 1;
        return gates[id]!.future;
      }
      return http.Response('not found', 404);
    });
    for (final id in ['packet-1', 'packet-2', 'packet-3']) {
      gates[id] = Completer<http.Response>();
    }
    final store = FinanceCardStore(gateway);
    addTearDown(store.dispose);

    final leases = [
      for (final id in ['packet-1', 'packet-2', 'packet-3'])
        store.lease(FinanceCardKey.redPacket(id))
    ];
    for (final lease in leases) {
      lease.setVisible(true);
      unawaited(lease.ensureFresh());
    }
    // 三个并发在途；先完成 1 和 3，2 保持挂起。
    gates['packet-1']!.complete(http.Response(
        jsonEncode({
          ..._packet(),
          'id': 'packet-1',
        }),
        200,
        headers: const {'content-type': 'application/json'}));
    gates['packet-3']!.complete(http.Response(
        jsonEncode({
          ..._packet(),
          'id': 'packet-3',
        }),
        200,
        headers: const {'content-type': 'application/json'}));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(leases[0].notifier.value.hasData, isTrue);
    expect(leases[2].notifier.value.hasData, isTrue);
    expect(leases[1].notifier.value.hasData, isFalse,
        reason: '挂起中的 packet-2 不得被其他 key 的结果污染');
    expect(leases[1].notifier.value.loading, isTrue);

    // 乐观补丁 packet-1 → packet-2/3 不受影响。
    store.patchDetail(const FinanceCardKey.redPacket('packet-1'),
        (detail) => {...detail, 'viewer_claim': {'amount': '1.66'}});
    expect(redPacketVisualState(leases[0].notifier.value.detail),
        RedPacketVisualState.claimed);
    expect(redPacketVisualState(leases[1].notifier.value.detail),
        RedPacketVisualState.available);
    expect(redPacketVisualState(leases[2].notifier.value.detail),
        RedPacketVisualState.available);

    gates['packet-2']!.complete(http.Response(
        jsonEncode({
          ..._packet(),
          'id': 'packet-2',
        }),
        200,
        headers: const {'content-type': 'application/json'}));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(leases[1].notifier.value.hasData, isTrue);
    for (final lease in leases) {
      lease.setVisible(false);
      lease.dispose();
    }
    store.dispose();
  });
}

final class _FakeGateway implements FinanceCardGateway {
  _FakeGateway(this.handler);
  final Future<http.Response> Function(http.Request request) handler;
  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => const Stream.empty();
  @override
  Future<String?> currentUserId() async => 'receiver-1';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) async {
    final response = await handler(http.Request('GET',
        Uri.parse('https://business.example/api/v1/red-packets/$id')));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) async {
    final response = await handler(http.Request('GET',
        Uri.parse('https://business.example/api/v1/chat-transfers/$id')));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

final class _GatedGateway implements FinanceCardGateway {
  _GatedGateway(this.detailOf);
  final Future<Map<String, dynamic>> Function(String id) detailOf;
  int detailCalls = 0;
  @override
  int get sessionEpoch => 1;
  @override
  Stream<void> get sessionInvalidations => const Stream.empty();
  @override
  Future<String?> currentUserId() async => 'receiver-1';
  @override
  Future<Map<String, dynamic>> redPacketDetail(String id) {
    detailCalls++;
    return detailOf(id);
  }
  @override
  Future<Map<String, dynamic>> chatTransferDetail(String id) => detailOf(id);
}
