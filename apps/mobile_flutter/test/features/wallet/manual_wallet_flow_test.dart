import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;

http.Response json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Future<BusinessApiClient> client(
    Future<http.Response> Function(http.Request) handler,
    {Map<String, dynamic>? capabilities}) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test', refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client:
          MockClient((request) => request.url.path.endsWith('/wallet/config')
              ? Future.value(json(capabilities ??
                  {
                    'funding_enabled': true,
                    'manual_payout_enabled': true,
                    'manual_payout_execution_enabled': true,
                    'conversion_enabled': true,
                  }))
              : handler(request)));
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200,
        scrollable: find.byType(Scrollable).first);
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('address only mode registers without signature or OTP controls',
      (tester) async {
    final posts = <http.Request>[];
    final api = await client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return json({...fixtures.binding, 'status': 'UNBOUND', 'version': 0});
      }
      posts.add(request);
      return json(fixtures.confirmed);
    }, capabilities: {
      'funding_enabled': true,
      'manual_payout_enabled': true,
      'manual_payout_execution_enabled': true,
      'user_auth_mode': 'address_only'
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    expect(find.text('设置身份验证器'), findsNothing);
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-address')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-register-address')), 200,
        scrollable: find.byType(Scrollable).first);
    await tap(tester, find.byKey(const Key('manual-register-address')));
    expect(posts.single.url.path, endsWith('/binding/address'));
    final payload = jsonDecode(posts.single.body) as Map;
    expect(payload.containsKey('signature'), isFalse);
    expect(payload.containsKey('mfa_proof'), isFalse);
  });

  testWidgets(
      'binding countdown expires without revealing or discarding the request',
      (tester) async {
    var now = DateTime.utc(2026, 9, 8);
    final api = await client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return json({...fixtures.binding, 'status': 'UNBOUND', 'version': 0});
      }
      return json({
        ...fixtures.challenge,
        'message': 'Exact private verification payload',
        'expires_at': now.add(const Duration(seconds: 5)).toIso8601String()
      });
    });
    await tester.pumpWidget(
        CupertinoApp(home: ManualWalletPage(client: api, clock: () => now)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await tap(tester, find.byKey(const Key('manual-challenge')));
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-countdown')), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('请在 0:05 内完成验证'), findsOneWidget);
    now = now.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('验证请求已过期，请刷新状态后重新获取'), findsOneWidget);
    expect(find.text('Exact private verification payload'), findsNothing);
    final store = ManualOperationStore(api);
    await store.initialize();
    expect(await store.read('binding'), isNotNull);
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
  });

  testWidgets(
      'binding copies exact server message and confirms without persisting signatures',
      (tester) async {
    final posts = <http.Request>[];
    final api = await client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return json({...fixtures.binding, 'status': 'UNBOUND', 'version': 0});
      }
      posts.add(request);
      if (request.url.path.endsWith('/challenges')) {
        return json(
            {...fixtures.challenge, 'message': 'Exact\nserver message  '});
      }
      return json(fixtures.confirmed);
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await tap(tester, find.byKey(const Key('manual-challenge')));
    expect(find.text('Exact\nserver message  '), findsNothing);
    expect(find.text('2 · 验证钱包归属'), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-details')), 200,
        scrollable: find.byType(Scrollable).first);
    await tap(tester, find.byKey(const Key('manual-binding-details')));
    expect(find.text('Exact\nserver message  '), findsOneWidget);
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-signature')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.byKey(const Key('manual-binding-signature')), 'private-signature');
    await tester.scrollUntilVisible(
        find.byKey(const Key('manual-binding-otp')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(
        find.byKey(const Key('manual-binding-otp')), '123456');
    await tap(tester, find.byKey(const Key('manual-binding-confirm')));
    expect(jsonDecode(posts.last.body)['signature'], 'private-signature');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().map(prefs.getString).join(),
        isNot(contains('private-signature')));
  });

  testWidgets(
      'quote displays locked destination and exact zero fee before confirmation',
      (tester) async {
    final api = await client((request) async => json(
        request.url.path.endsWith('/binding')
            ? fixtures.binding
            : fixtures.quote));
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await tap(tester, find.text('提现'));
    await tester.enterText(find.byKey(const Key('manual-payout-amount')), '10');
    await tap(tester, find.byKey(const Key('manual-quote-create')));
    expect(find.text('target'), findsOneWidget);
    expect(find.byKey(const Key('manual-target-copy')), findsOneWidget);
    expect(find.text('服务费 USDT：0.000000'), findsOneWidget);
    expect(find.text('总冻结 USDT：10.000000'), findsOneWidget);
    expect(find.byKey(const Key('wallet-withdraw-address')), findsNothing);
  });

  testWidgets(
      'unknown payout restarts with original quote and key but fresh OTP',
      (tester) async {
    final posts = <http.Request>[];
    final api = await client((request) async {
      if (request.url.path.endsWith('/binding')) return json(fixtures.binding);
      if (request.url.path.endsWith('/payouts')) {
        posts.add(request);
        return json(fixtures.payout);
      }
      throw StateError('Unexpected request');
    });
    final store = ManualOperationStore(api);
    await store.initialize();
    final original =
        await store.begin('payout', {'quote_id': 'original-quote'});
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await tap(tester, find.text('提现'));
    await tester.enterText(
        find.byKey(const Key('manual-payout-otp')), '654321');
    await tap(tester, find.byKey(const Key('manual-payout-confirm')));
    expect(posts, hasLength(1));
    expect(posts.single.headers['Idempotency-Key'], original['key']);
    expect(jsonDecode(posts.single.body),
        {'quote_id': 'original-quote', 'mfa_proof': '654321'});
    final prefs = await SharedPreferences.getInstance();
    expect(
        prefs.getKeys().map(prefs.getString).join(), isNot(contains('654321')));
    expect(find.text('状态：requested'), findsOneWidget);
  });

  testWidgets('deposit unknown response retains exact decimal across restart',
      (tester) async {
    final posts = <http.Request>[];
    final api = await client((request) async {
      if (request.url.path.endsWith('/binding')) return json(fixtures.binding);
      if (request.url.path.endsWith('/deposit-intents')) {
        posts.add(request);
        if (posts.length == 1) throw Exception('offline');
        return json({...fixtures.intent, 'expected_amount': '10.000001'});
      }
      throw StateError('Unexpected request');
    });
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await tap(tester, find.text('充值'));
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10.000001');
    await tap(tester, find.byKey(const Key('manual-deposit-create')));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await tap(tester, find.text('充值'));
    await tap(tester, find.byKey(const Key('manual-deposit-create')));
    expect(posts, hasLength(2));
    expect(posts[0].body, posts[1].body);
    expect(posts[0].headers['Idempotency-Key'],
        posts[1].headers['Idempotency-Key']);
    expect(jsonDecode(posts[1].body)['amount'], '10.000001');
    expect(find.text('金额 USDT：10.000001'), findsOneWidget);
  });
}
