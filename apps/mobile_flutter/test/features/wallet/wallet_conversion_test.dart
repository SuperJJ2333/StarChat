import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_conversion_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'wallet_page_audit_test.dart' show MemoryStore;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<BusinessApiClient> api(
      Future<http.Response> Function(http.Request) handler) async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken:
            'e30.${base64Url.encode(utf8.encode('{"sub":"alice"}'))}.test',
        refreshToken: 'test');
    return BusinessApiClient(
        baseUri: Uri.parse('https://wallet.example'),
        sessionStore: store,
        client: MockClient(handler));
  }

  testWidgets('conversion is disabled unless the server enables it',
      (tester) async {
    final client = await api((_) async => http.Response('{}', 200));
    await tester.pumpWidget(CupertinoApp(
        home: WalletConversionCard(
            api: client, enabled: false, onCompleted: () {})));
    await tester.pumpAndSettle();
    expect(find.text('兑换暂未开放'), findsOneWidget);
    expect(find.byKey(const Key('wallet-convert-submit')), findsNothing);
  });

  testWidgets('conversion sends strings and refreshes after confirmation',
      (tester) async {
    http.Request? captured;
    var refreshed = 0;
    final client = await api((request) async {
      captured = request;
      return http.Response(
          '{"id":"c1","status":"COMPLETED","target_amount":"1.23"}', 201);
    });
    await tester.pumpWidget(CupertinoApp(
        home: WalletConversionCard(
            api: client, enabled: true, onCompleted: () => refreshed++)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('wallet-convert-amount')), '1.234567');
    await tester.tap(find.byKey(const Key('wallet-convert-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1.23'), findsWidgets);
    await tester.tap(find.byKey(const Key('wallet-convert-confirm')));
    await tester.pumpAndSettle();
    expect(jsonDecode(captured!.body)['amount'], '1.234567');
    expect(captured!.headers['Idempotency-Key'], isNotEmpty);
    expect(refreshed, 1);
    expect(find.textContaining('兑换成功'), findsOneWidget);
  });

  testWidgets('response loss and page restart reuse the stored intent',
      (tester) async {
    final keys = <String>[];
    final client = await api((request) async {
      keys.add(request.headers['Idempotency-Key']!);
      if (keys.length == 1) throw http.ClientException('response lost');
      return http.Response(
          '{"id":"c1","status":"COMPLETED","target_amount":"2.00"}', 201);
    });
    Widget page() => CupertinoApp(
        home: WalletConversionCard(
            api: client, enabled: true, onCompleted: () {}));
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('wallet-convert-amount')), '2');
    await tester.tap(find.byKey(const Key('wallet-convert-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wallet-convert-confirm')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wallet-convert-submit')));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys[1], keys[0]);
  });

  testWidgets('same account token refresh retries conversion with the same key',
      (tester) async {
    final requests = <http.Request>[];
    var completed = 0;
    const renewed = 'e30.eyJzdWIiOiJhbGljZSJ9.renewed';
    final client = await api((request) async {
      if (request.url.path.endsWith('/auth/refresh')) {
        return http.Response(
            jsonEncode({
              'access_token': renewed,
              'refresh_token': 'renewed-refresh',
            }),
            200);
      }
      requests.add(request);
      if (requests.length == 1) return http.Response('{}', 401);
      return http.Response(
          '{"id":"c1","status":"COMPLETED","target_amount":"2.00"}', 201);
    });
    await tester.pumpWidget(CupertinoApp(
        home: WalletConversionCard(
            api: client, enabled: true, onCompleted: () => completed++)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('wallet-convert-amount')), '2');
    await tester.tap(find.byKey(const Key('wallet-convert-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wallet-convert-confirm')));
    await tester.pumpAndSettle();
    expect(requests, hasLength(2));
    expect(requests.last.headers['Idempotency-Key'],
        requests.first.headers['Idempotency-Key']);
    expect(requests.last.headers['Authorization'], 'Bearer $renewed');
    expect(requests.last.body, requests.first.body);
    expect(completed, 1);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wallet.conversion.v1:https://wallet.example:alice'),
        isNull);
  });

  for (final switchAtRefresh in [false, true]) {
    testWidgets(
        'conversion keeps original account across ${switchAtRefresh ? 'refresh' : 'confirmation'}',
        (tester) async {
      var conversions = 0;
      var completed = 0;
      const bob = 'e30.eyJzdWIiOiJib2IifQ.test';
      final client = await api((request) async {
        if (request.url.path.endsWith('/auth/refresh')) {
          return http.Response(
              jsonEncode({
                'access_token': bob,
                'refresh_token': 'bob-refresh',
              }),
              200);
        }
        conversions++;
        if (switchAtRefresh && conversions == 1) {
          return http.Response('{}', 401);
        }
        return http.Response(
            '{"id":"c1","status":"COMPLETED","target_amount":"2.00"}', 201);
      });
      await tester.pumpWidget(CupertinoApp(
          home: WalletConversionCard(
              api: client, enabled: true, onCompleted: () => completed++)));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('wallet-convert-amount')), '2');
      await tester.tap(find.byKey(const Key('wallet-convert-submit')));
      await tester.pumpAndSettle();
      if (!switchAtRefresh) {
        await client.sessionStore
            .saveSession(accessToken: bob, refreshToken: 'bob-refresh');
      }
      await tester.tap(find.byKey(const Key('wallet-convert-confirm')));
      await tester.pumpAndSettle();
      expect(conversions, switchAtRefresh ? 1 : 0);
      expect(completed, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(
          prefs.getString('wallet.conversion.v1:https://wallet.example:alice'),
          isNotNull);
      expect(prefs.getString('wallet.conversion.v1:https://wallet.example:bob'),
          isNull);
    });
  }
}
