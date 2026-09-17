import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

final _capabilities = <String, dynamic>{
  'funding_enabled': true,
  'manual_payout_enabled': true,
  'manual_payout_execution_enabled': true,
  'conversion_enabled': true,
  'caibi_payout_enabled': true,
};

/// 与 flow.client 同构，但能力配置由用例控制（可挂起、可失败）。
Future<BusinessApiClient> walletClient(
  Future<http.Response> Function() config, {
  Map<String, dynamic>? binding,
}) async {
  final session = SecureSessionStore(fixtures.MemoryStore());
  await session.saveSession(
      accessToken: 'e30.eyJzdWIiOiJhbGljZSJ9.test', refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: session,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/wallet/config')) return config();
        if (request.url.path.endsWith('/wallet/balances/me')) {
          return flow.json({'caibi_available': '100.00'});
        }
        if (request.url.path.endsWith('/binding')) {
          return flow.json(binding ?? fixtures.binding);
        }
        return flow.json({});
      }));
}

http.Response unavailable() => http.Response(
    '{"error":{"code":"WALLET_CONFIG_UNAVAILABLE","message":"unavailable"}}',
    503,
    headers: {'content-type': 'application/json'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('能力加载中不得闪现「功能状态暂不可用」，加载成功也不提示', (tester) async {
    final gate = Completer<http.Response>();
    final api = await walletClient(() => gate.future);

    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('功能状态暂不可用'), findsNothing,
        reason: '请求还在途时不得先报警告再消失（用户报的闪烁）');

    gate.complete(flow.json(_capabilities));
    await tester.pumpAndSettle();
    expect(find.textContaining('功能状态暂不可用'), findsNothing);
  });

  testWidgets('能力真正加载失败时才提示，且提示保持可见', (tester) async {
    var attempts = 0;
    final api = await walletClient(() async {
      attempts++;
      return unavailable();
    });

    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    expect(attempts, greaterThan(0));
    expect(find.textContaining('功能状态暂不可用'), findsOneWidget,
        reason: '真正失败必须让用户看到，而不是静默');
  });

  testWidgets('已知能力后一次刷新失败不得把已可用状态打回警告', (tester) async {
    final gate = Completer<http.Response>();
    var attempts = 0;
    final api = await walletClient(() {
      attempts++;
      // 首次成功，之后的刷新挂起 → 期间不得闪警告。
      return attempts == 1
          ? Future.value(flow.json(_capabilities))
          : gate.future;
    });

    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('功能状态暂不可用'), findsNothing);

    await flow.tap(tester, find.byKey(const Key('manual-refresh')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('功能状态暂不可用'), findsNothing,
        reason: '刷新期间沿用上次已知能力，不得回退成不可用警告');

    gate.complete(flow.json(_capabilities));
    await tester.pumpAndSettle();
    expect(find.textContaining('功能状态暂不可用'), findsNothing);
  });

  testWidgets('钱包根页面的刷新按钮位于顶部导航栏右侧', (tester) async {
    final api = await flow.client((request) async =>
        flow.json(request.url.path.endsWith('/binding') ? fixtures.binding : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();

    expect(
        find.descendant(
            of: find.byType(CupertinoNavigationBar),
            matching: find.byKey(const Key('manual-refresh'))),
        findsOneWidget,
        reason: '刷新按钮必须落在顶部导航栏里');
    expect(
        find.descendant(
            of: find.byKey(const Key('wallet-page-list')),
            matching: find.byKey(const Key('manual-refresh'))),
        findsNothing,
        reason: '列表内不再重复放刷新按钮');
    expect(
        find.descendant(
            of: find.byType(CupertinoNavigationBar),
            matching: find.text('钱包')),
        findsOneWidget);
  });

  test('AppHome 的钱包入口不再自建导航栏（避免与钱包页导航栏重复）', () {
    final source = File('lib/app_home.dart').readAsStringSync();
    final walletScaffold = RegExp(
        r"CupertinoPageScaffold\([\s\S]{0,400}?middle: Text\('钱包'\)",
        multiLine: true);
    expect(walletScaffold.hasMatch(source), isFalse,
        reason: '钱包导航栏由钱包页自己提供（含刷新按钮）');
    expect(source, contains('WalletPage(api: widget.api)'));
    expect(source, contains('WalletPage(api: api)'));
  });
}
