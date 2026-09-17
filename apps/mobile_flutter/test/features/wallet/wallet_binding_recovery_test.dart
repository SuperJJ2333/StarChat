import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

http.Response rejected(String code) => http.Response(
    jsonEncode({
      'error': {'code': code, 'message': '请求已拒绝'}
    }),
    409,
    headers: {'content-type': 'application/json'});

/// 新用户视角：未绑定、版本 0。
final unbound = <String, dynamic>{
  'status': 'UNBOUND',
  'id': null,
  'version': 0,
  'masked_address': null,
  'address': null,
  'pending_id': null,
  'next_rebind_at': null,
  'binding_enabled': true,
  'unavailable_dependencies': <String>[],
  'rebind_interval_days': 30,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('被他人登记的地址失败后清除草稿、恢复可编辑并提示更换地址', (tester) async {
    final posts = <http.Request>[];
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/wallet/binding')) {
        return flow.json(unbound);
      }
      if (request.url.path.endsWith('/wallet/binding/address')) {
        posts.add(request);
        return posts.length == 1
            ? rejected('WALLET_ADDRESS_OWNED')
            : flow.json(fixtures.confirmed);
      }
      return flow.json({});
    }, capabilities: {'user_auth_mode': 'address_only'});

    final store = ManualOperationStore(api);
    await store.initialize();

    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openBinding(tester);

    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'2' * 33}');
    await flow.tap(tester, find.byKey(const Key('manual-register-address')));

    // 失败必须被解释，而且必须明确引导用户更换地址。
    expect(find.byKey(const Key('manual-feedback')), findsOneWidget);
    expect(find.textContaining('已被其他账号登记'), findsOneWidget);
    expect(find.textContaining('更换'), findsWidgets);

    // 关键回归：被拒地址不得锁死输入框，也不得留下无法放弃的草稿。
    final addressField = tester.widget<CupertinoTextField>(
        find.byKey(const Key('manual-binding-address')));
    expect(addressField.enabled, isTrue,
        reason: '被他人登记的地址必须能删除并重新输入');
    expect(await store.read('binding'), isNull,
        reason: '终局失败的登记草稿必须清除，否则会一直重放同一个被拒地址');

    // 换成自己的地址后可以继续登记。
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'3' * 33}');
    await flow.tap(tester, find.byKey(const Key('manual-register-address')));
    expect(posts, hasLength(2), reason: '必须真的重新提交新地址');
    expect(await store.read('binding'), isNotNull);
    expect((await store.read('binding'))!['address'], 'T${'3' * 33}');
  });

  testWidgets('地址格式错误同样释放输入框，不用等用户找出口', (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/wallet/binding')) {
        return flow.json(unbound);
      }
      if (request.url.path.endsWith('/wallet/binding/address')) {
        return rejected('WALLET_ADDRESS_INVALID');
      }
      return flow.json({});
    }, capabilities: {'user_auth_mode': 'address_only'});
    final store = ManualOperationStore(api);
    await store.initialize();

    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openBinding(tester);
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'not-a-tron-address');
    await flow.tap(tester, find.byKey(const Key('manual-register-address')));

    expect(find.textContaining('地址格式不正确'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-binding-address')))
            .enabled,
        isTrue);
    expect(await store.read('binding'), isNull);
  });

  testWidgets('已绑定用户有显式「更改绑定」按钮并展示 30 天限制', (tester) async {
    final api = await flow.client(
        (request) async => flow.json(request.url.path.endsWith('/binding')
            ? {
                ...fixtures.binding,
                'next_rebind_at': '2026-10-15T06:30:00+00:00',
              }
            : {}));
    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('manual-wallet-rebind')), findsOneWidget);
    expect(find.text('更改绑定'), findsOneWidget,
        reason: '入口必须有文字，不能只有一个铅笔图标');
    expect(find.textContaining('下次可改绑'), findsOneWidget,
        reason: '30 天限制必须可见（含具体时间）');

    await flow.openBinding(tester);
    expect(find.text('更换钱包地址'), findsOneWidget);
    expect(find.textContaining('未满 30 天'), findsOneWidget,
        reason: '冷却期内必须解释为什么现在不能改');
  });

  testWidgets('已绑定但未在冷却期时可以直接进入更换流程', (tester) async {
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json({
          ...fixtures.binding,
          'next_rebind_at': '2026-09-01T00:00:00+00:00',
        });
      }
      return flow.json({});
    }, capabilities: {'user_auth_mode': 'address_only'});
    await tester
        .pumpWidget(CupertinoApp(home: ManualWalletPage(client: api)));
    await tester.pumpAndSettle();
    await flow.openBinding(tester);

    expect(find.textContaining('未满 30 天'), findsNothing);
    await tester.enterText(
        find.byKey(const Key('manual-binding-address')), 'T${'4' * 33}');
    expect(
        tester
            .widget<CupertinoTextField>(
                find.byKey(const Key('manual-binding-address')))
            .enabled,
        isTrue);
  });
}
