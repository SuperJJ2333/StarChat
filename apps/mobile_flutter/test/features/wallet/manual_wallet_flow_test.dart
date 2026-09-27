import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/performance_trace.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/features/finance/wallet_entry_store.dart';

import 'manual_wallet_api_test.dart' as fixtures;

http.Response json(Object body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Future<BusinessApiClient> client(
    Future<http.Response> Function(http.Request) handler,
    {Map<String, dynamic>? capabilities,
    Map<String, dynamic>? balance,
    PerformanceTraceRecorder? performanceRecorder}) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test', refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      performanceRecorder: performanceRecorder,
      client:
          MockClient((request) => request.url.path.endsWith('/wallet/config')
              ? Future.value(json(capabilities ??
                  {
                    'funding_enabled': true,
                    'manual_payout_enabled': true,
                    'manual_payout_execution_enabled': true,
                    'conversion_enabled': true,
                    'caibi_payout_enabled': true,
                  }))
              : request.url.path.endsWith('/wallet/balances/me')
                  ? Future.value(json(balance ?? {'caibi_available': '100.00'}))
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

Future<void> openBinding(WidgetTester tester) =>
    tap(tester, find.byKey(const Key('manual-wallet-rebind')));

Future<void> openDeposit(WidgetTester tester) =>
    tap(tester, find.byKey(const Key('manual-deposit-open')));

Future<void> openPayout(WidgetTester tester) =>
    tap(tester, find.byKey(const Key('manual-payout-open')));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 进入态 Store 是进程内共享的（键 = 钱包作用域 + 会话 epoch）：用例之间必须
    // 清空，否则上一个用例的缓存会泄漏到下一个用例的「首次进入」断言。
    WalletEntryStores.disposeAll();
  });

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
    await openBinding(tester);
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
    await openBinding(tester);
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
    await openBinding(tester);
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
    final api = await client(
        (request) async => json(request.url.path.endsWith('/binding')
            ? fixtures.binding
            : {
                ...fixtures.quote,
                'funding_asset': 'CAIBI',
                'funding_amount': '10.00',
              }));
    await tester.pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await openPayout(tester);
    await tester.enterText(find.byKey(const Key('manual-payout-amount')), '10');
    await tap(tester, find.byKey(const Key('manual-quote-create')));
    expect(find.text('target'), findsOneWidget);
    expect(find.byKey(const Key('manual-target-copy')), findsOneWidget);
    // 报价明细改为键值分组卡片：标签与数值分列显示（design-demo 对齐）。
    expect(find.text('扣除点钻'), findsOneWidget);
    expect(find.text('10.00'), findsWidgets);
    expect(find.text('服务费 USDT'), findsOneWidget);
    expect(find.text('0.000000'), findsWidgets);
    expect(find.text('总冻结 USDT'), findsNothing);
    expect(find.byKey(const Key('wallet-withdraw-address')), findsNothing);
  });

  testWidgets(
      'unknown USDT payout replays its original quote and idempotency key before new authorization',
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
    await tap(tester, find.byKey(const Key('manual-payout-confirm')));
    expect(posts, hasLength(1));
    expect(posts.single.headers['Idempotency-Key'], original['key']);
    expect(jsonDecode(posts.single.body), {'quote_id': 'original-quote'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().map(prefs.getString).join(),
        isNot(contains('authorization')));
    expect(find.text('状态'), findsWidgets);
    expect(find.text('requested'), findsWidgets);
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
    expect(find.text('金额 USDT'), findsOneWidget);
    expect(find.text('10.000001'), findsWidgets);
  });
}
