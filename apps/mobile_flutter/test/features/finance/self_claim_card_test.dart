import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_card_store.dart';
import 'package:liuhetong_mobile/features/finance/finance_message_entry.dart';

/// 复现（用户反馈）：单独一个（单份）红包，发布者自己领取后，
/// 聊天卡片应切换为“已领取”视觉态（viewer_claim 命中）。
void main() {
  testWidgets('发布者领取自己的单份红包后，卡片切换为已领取',
      (tester) async {
    var claimed = false;
    Map<String, dynamic> packet({
      required bool isClaimed,
      required String claimerId,
    }) =>
        {
          'id': 'p1',
          'sender_id': 'sender-1',
          'mode': 'RANDOM',
          'status': isClaimed ? 'COMPLETED' : 'OPEN',
          'total': '1.00',
          'share_count': 1,
          'claimed_count': isClaimed ? 1 : 0,
          'room_id': '!room:t',
          'expires_at': '2099-01-01T00:00:00+00:00',
          'server_time': '2026-01-01T00:00:00+00:00',
          'viewer_claim': isClaimed
              ? {
                  'user_id': claimerId,
                  'amount': '1.00',
                  'claimed_at': '2026-01-01T00:00:01+00:00',
                }
              : null,
          'claims': isClaimed
              ? [
                  {
                    'user_id': claimerId,
                    'amount': '1.00',
                    'claimed_at': '2026-01-01T00:00:01+00:00',
                  }
                ]
              : <Map<String, dynamic>>[],
        };

    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/p1') {
        return _json(packet(
            isClaimed: claimed,
            // token sub = sender-1：发布者视角（自己领取）。
            claimerId: 'sender-1'));
      }
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);

    await _pumpEntry(tester, store: store, api: api, id: 'p1');
    await tester.pumpAndSettle();
    expect(find.text('领取红包'), findsOneWidget, reason: '领取前：可领取封面');

    // 发布者自己领取（viewer_claim 命中发布者）→ invalidate → 刷新。
    claimed = true;
    store.invalidate(const FinanceCardKey(FinanceCardKind.redPacket, 'p1'));
    await tester.pumpAndSettle();

    expect(find.text('已领取'), findsOneWidget, reason: '发布者领取后应显示已领取');
    expect(find.text('已领完'), findsNothing);
    expect(find.text('领取红包'), findsNothing);
  });

  testWidgets('发布者未领取、他人领完单份红包显示已领完（非已领取）',
      (tester) async {
    final api = await _api((request) async {
      if (request.url.path == '/api/v1/red-packets/p1') {
        return _json({
          'id': 'p1',
          'sender_id': 'sender-1',
          'mode': 'RANDOM',
          'status': 'COMPLETED',
          'total': '1.00',
          'share_count': 1,
          'claimed_count': 1,
          'room_id': '!room:t',
          'expires_at': '2099-01-01T00:00:00+00:00',
          'server_time': '2026-01-01T00:00:00+00:00',
          'viewer_claim': null,
          'claims': [
            {
              'user_id': 'other-2',
              'amount': '1.00',
              'claimed_at': '2026-01-01T00:00:01+00:00',
            }
          ],
        });
      }
      return http.Response('not found', 404);
    });
    final store = FinanceCardStore(BusinessFinanceCardGateway(api));
    addTearDown(store.dispose);
    await _pumpEntry(tester, store: store, api: api, id: 'p1');
    await tester.pumpAndSettle();
    expect(find.text('已领完'), findsOneWidget);
    expect(find.text('已领取'), findsNothing);
  });
}

Future<BusinessApiClient> _api(
    Future<http.Response> Function(http.Request request) handler) async {
  final session = SecureSessionStore(_MemoryStore());
  await session.saveSession(
    accessToken: 'eyJhbGciOiJub25lIn0.eyJzdWIiOiJzZW5kZXItMSJ9.sig',
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

http.Response _json(Object value) => http.Response(
    jsonEncode(value), 200,
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _pumpEntry(
  WidgetTester tester, {
  required FinanceCardStore store,
  required BusinessApiClient api,
  required String id,
}) =>
    tester.pumpWidget(CupertinoApp(
      home: FinanceMessageEntry(
        store: store,
        api: api,
        kind: FinanceCardKind.redPacket,
        id: id,
        greeting: '恭喜发财',
        amount: '1.00',
        isOwn: true,
        senderName: '发送者',
      ),
    ));
