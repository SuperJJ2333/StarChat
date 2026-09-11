import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_entry.dart';
import 'package:liuhetong_mobile/features/ledger/ledger_pages.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_detail_page.dart';
import 'package:liuhetong_mobile/features/redpacket/red_packet_claim_dialog.dart';
import 'package:liuhetong_mobile/features/transfer/chat_transfer_detail_sheet.dart';

void main() {
  testWidgets('claimed red packet opens its detail without a claim write',
      (tester) async {
    var details = 0;
    var claims = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        details++;
        return _json({
          ..._packet(roomId: null),
          'viewer_claim': {'amount': '8.88'}
        });
      }
      if (request.url.path == '/api/v1/red-packets/packet-1/claims') {
        claims++;
        return _json({});
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.redPacket,
        id: 'packet-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pumpAndSettle();

    expect(find.byType(RedPacketClaimDetailPage), findsOneWidget);
    expect(claims, 0);
    expect(details, greaterThanOrEqualTo(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('claim write invalidates only its card and renders claimed state',
      (tester) async {
    var claimed = false;
    var claimPosts = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        return _json(_packet(
            roomId: 'room-1',
            viewerClaim: claimed ? {'amount': '8.88'} : null));
      }
      if (request.url.path == '/api/v1/red-packets/packet-1/claims') {
        claimPosts++;
        claimed = true;
        return _json({'amount': '8.88'});
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.redPacket,
        id: 'packet-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('red-packet-claim-open-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('red-packet-claim-close')));
    await tester.pumpAndSettle();

    expect(claimPosts, 1);
    expect(find.text('已领取'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('private red-packet sender opens detail without a claim write',
      (tester) async {
    var claims = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        return _json({..._packet(roomId: null), 'sender_id': 'receiver-1'});
      }
      if (request.url.path == '/api/v1/red-packets/packet-1/claims') {
        claims++;
        return _json({});
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.redPacket,
        id: 'packet-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pumpAndSettle();

    expect(find.byType(RedPacketClaimDetailPage), findsOneWidget);
    expect(claims, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unclaimed red packet opens the claim dialog', (tester) async {
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/packet-1') {
        return _json(_packet(roomId: 'room-1'));
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.redPacket,
        id: 'packet-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-red-packet-card')));
    await tester.pumpAndSettle();

    expect(find.byType(RedPacketClaimDialog), findsOneWidget);
    expect(find.byKey(const Key('red-packet-claim-dialog')), findsOneWidget);
    expect(find.byType(RedPacketClaimDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('accepted transfer opens receipt and its real ledger entry',
      (tester) async {
    var transferReads = 0;
    var ledgerReads = 0;
    final api = await _api((request) async {
      switch (request.url.path) {
        case '/api/v1/chat-transfers/transfer-1':
          transferReads++;
          return _json(_transfer());
        case '/api/v1/ledger/transactions/me/bill-1':
          ledgerReads++;
          return _json(_ledgerDetail());
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.transfer,
        id: 'transfer-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pumpAndSettle();
    expect(find.byType(ChatTransferDetailSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-transfer-detail-ledger')));
    await tester.pumpAndSettle();
    expect(find.byType(LedgerDetailPage), findsOneWidget);
    expect(transferReads, greaterThanOrEqualTo(2));
    expect(ledgerReads, 1);
    expect(find.text('8.88 点钻'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('accept write invalidates the card and renders receiver success',
      (tester) async {
    var accepted = false;
    var accepts = 0;
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/chat-transfers/transfer-1') {
        return _json(
            {..._transfer(), 'status': accepted ? 'ACCEPTED' : 'PENDING'});
      }
      if (request.url.path == '/api/v1/chat-transfers/transfer-1/accept') {
        accepts++;
        accepted = true;
        return _json(_transfer());
      }
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.transfer,
        id: 'transfer-1');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('chat-transfer-detail-accept')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(accepts, 1);
    expect(find.text('转账已收款'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('double tap has one route while its forced detail read is held',
      (tester) async {
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
    final observer = _RouteObserver();
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        navigatorObservers: [observer],
        kind: FinanceCardKind.transfer,
        id: 'transfer-1');
    await tester.pump();
    await tester.pump();
    observer.pushes = 0;
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pump();
    expect(reads, 2);

    held.complete(_json(_transfer()));
    await tester.pumpAndSettle();
    expect(observer.pushes, 1);
    expect(find.byType(ChatTransferDetailSheet, skipOffstage: false),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'rebound entry rejects the old held read and the new id remains tappable',
      (tester) async {
    final oldHeld = Completer<http.Response>();
    var oldReads = 0;
    final observer = _RouteObserver();
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/chat-transfers/old') {
        oldReads++;
        return oldReads == 1
            ? _json({..._transfer(), 'id': 'old'})
            : oldHeld.future;
      }
      if (request.url.path == '/api/v1/chat-transfers/new') {
        return _json({..._transfer(), 'id': 'new'});
      }
      if (request.url.path == '/api/v1/friends') return _json({'items': []});
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester,
        store: store,
        api: api,
        navigatorObservers: [observer],
        kind: FinanceCardKind.transfer,
        id: 'old');
    await tester.pump();
    await tester.pump();
    observer.pushes = 0;
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pump();
    expect(oldReads, 2);

    await _pumpEntry(tester,
        store: store,
        api: api,
        navigatorObservers: [observer],
        kind: FinanceCardKind.transfer,
        id: 'new');
    await tester.pump();
    await tester.pump();
    oldHeld.complete(_json({..._transfer(), 'id': 'old'}));
    await tester.pumpAndSettle();
    expect(observer.pushes, 0);

    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pumpAndSettle();
    expect(observer.pushes, 1);
    expect(
        tester
            .widget<ChatTransferDetailSheet>(
                find.byType(ChatTransferDetailSheet, skipOffstage: false))
            .transferId,
        'new');
    expect(tester.takeException(), isNull);
  });
  testWidgets('held old-epoch card read creates no route', (tester) async {
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

    await _pumpEntry(tester,
        store: store,
        api: api,
        kind: FinanceCardKind.transfer,
        id: 'transfer-1');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('wechat-transfer-card')));
    await tester.pump();
    expect(reads, 2);

    await api.clearLocalSession();
    held.complete(_json(_transfer()));
    await tester.pumpAndSettle();
    expect(find.byType(ChatTransferDetailSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpEntry(
  WidgetTester tester, {
  required FinanceCardStore store,
  required BusinessApiClient api,
  required FinanceCardKind kind,
  required String id,
  List<NavigatorObserver> navigatorObservers = const [],
}) =>
    tester.pumpWidget(CupertinoApp(
      navigatorObservers: navigatorObservers,
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

Map<String, dynamic> _packet(
        {Map<String, dynamic>? viewerClaim, Object? roomId}) =>
    {
      'id': 'packet-1',
      'status': 'OPEN',
      'amount': '8.88',
      'viewer_claim': viewerClaim,
      'room_id': roomId,
      'server_time': '2026-09-11T10:00:00Z',
      'expires_at': '2026-09-11T11:00:00Z',
    };

Map<String, dynamic> _transfer() => {
      'id': 'transfer-1',
      'status': 'ACCEPTED',
      'sender_id': 'sender-1',
      'receiver_id': 'receiver-1',
      'amount': '8.88',
      'note': '午饭',
      'created_at': '2026-09-11T10:00:00Z',
      'accepted_at': '2026-09-11T10:01:00Z',
      'bill_id': 'bill-1',
    };

Map<String, dynamic> _ledgerDetail() => {
      'id': 'bill-1',
      'asset': 'CAIBI',
      'kind': 'transfer',
      'status': 'COMPLETED',
      'amount': '8.88',
      'transfer_amount': '8.88',
      'fee': '0.00',
      'created_at': '2026-09-11T10:01:00Z',
      'transfer_created_at': '2026-09-11T10:00:00Z',
      'accepted_at': '2026-09-11T10:01:00Z',
      'note': '午饭',
    };
http.Response _json(Map<String, dynamic> value) => http.Response(
      jsonEncode(value),
      200,
      headers: const {'content-type': 'application/json'},
    );

Future<BusinessApiClient> _api(
    Future<http.Response> Function(http.Request request) handler) async {
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

final class _MemoryStore implements SecureKeyValueStore {
  final _values = <String, String>{};
  @override
  Future<void> delete(String key) async => _values.remove(key);
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

final class _RouteObserver extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    super.didPush(route, previousRoute);
  }
}
