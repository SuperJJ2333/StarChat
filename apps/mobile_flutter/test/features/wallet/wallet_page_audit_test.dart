import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 审计 U01/U02：提现按钮提交互斥 + 页面生命周期保护。
/// 经真实 BusinessApiClient + MockClient 驱动（覆盖完整请求路径）。
final class MemoryStore implements SecureKeyValueStore {
  final _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);
}

Future<BusinessApiClient> walletApi(
  http.Response Function(http.Request) handler, {
  Duration? latency,
}) async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(accessToken: 'access', refreshToken: 'refresh');
  return BusinessApiClient(
    baseUri: Uri.parse('https://business.example'),
    sessionStore: store,
    client: MockClient((request) async {
      if (latency != null) await Future<void>.delayed(latency);
      return await handler(request);
    }),
  );
}

http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Future<void> _fillForm(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('wallet-withdraw-amount')), '5');
  await tester.enterText(find.byKey(const Key('wallet-withdraw-address')),
      'T' + '2' * 33);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('U01：快速双击只创建一单（提交互斥 + loading 禁用）',
      (tester) async {
    var withdrawalRequests = 0;
    final api = await walletApi((request) {
      if (request.url.path.endsWith('/wallet/withdrawals')) {
        withdrawalRequests++;
        return _json({'id': 'wd-1', 'status': 'REQUESTED'}, status: 201);
      }
      if (request.url.path.endsWith('/wallet/withdrawals/wd-1')) {
        return _json({'id': 'wd-1', 'status': 'CHAIN_CONFIRMED'});
      }
      if (request.url.path.endsWith('/wallet/balances/me')) {
        return _json({'asset': 'USDT-TRC20', 'balance': '10.000000'});
      }
      return _json({});
    }, latency: const Duration(milliseconds: 200));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await _fillForm(tester);

    final button = find.byKey(const Key('wallet-withdraw-submit'));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 50));
    // 第二次点击命中提交中禁用态。
    await tester.tap(button, warnIfMissed: false);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(withdrawalRequests, 1, reason: '一次明确意图只创建一单');
  });

  testWidgets('U02：提交期间退出页面不报错（mounted 保护 + 资源释放）',
      (tester) async {
    final api = await walletApi((request) {
      if (request.url.path.endsWith('/wallet/withdrawals')) {
        return _json({'id': 'wd-2', 'status': 'REQUESTED'}, status: 201);
      }
      return _json({});
    }, latency: const Duration(milliseconds: 200));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('wallet-withdraw-submit')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const CupertinoApp(home: SizedBox()));
    // 推进足够时间：在途请求及其超时定时器全部收敛。
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull, reason: '页面销毁后不得有未捕获异常');
  });

  testWidgets('U02：轮询串行、终态自动停止并展示状态', (tester) async {
    final api = await walletApi((request) {
      if (request.url.path.endsWith('/wallet/withdrawals')) {
        return _json({'id': 'wd-3', 'status': 'REQUESTED'}, status: 201);
      }
      if (request.url.path.endsWith('/wallet/withdrawals/wd-3')) {
        return _json({'id': 'wd-3', 'status': 'CHAIN_CONFIRMED'});
      }
      return _json({});
    });
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await _fillForm(tester);
    await tester.tap(find.byKey(const Key('wallet-withdraw-submit')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 25));
    expect(find.text('提现状态：CHAIN_CONFIRMED'), findsOneWidget);
  });
}
