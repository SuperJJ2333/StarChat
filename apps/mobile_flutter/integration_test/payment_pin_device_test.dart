import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/payment_pin/payment_pin_dialog.dart';

// Isolated device UI + real API serializer tests. This fixture never contacts
// production, never writes secure storage and never creates financial records.
final class _MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultTestTimeout = const Timeout(Duration(minutes: 3));
  var surfaceConverted = false;

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (Platform.isAndroid && !surfaceConverted) {
      await binding.convertFlutterSurfaceToImage();
      surfaceConverted = true;
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot(name);
  }

  Future<void> key(WidgetTester tester, String value) async {
    final target = find.byKey(ValueKey('payment-pin-key-$value'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pump();
  }

  Future<void> digits(WidgetTester tester, String value) async {
    for (final digit in value.split('')) {
      await key(tester, digit);
    }
  }

  Future<void> confirm(WidgetTester tester) async {
    final target = find.byKey(const ValueKey('payment-pin-confirm'));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  testWidgets('isolated Redmi setup and both payment purposes', (tester) async {
    const pin = '012345';
    const password = 'synthetic-login-only';
    var configured = false;
    var setupCalls = 0;
    var authorizationCalls = 0;
    final checkedActions = <String>[];
    final operationKeys = <String, String>{};
    final sessions = SecureSessionStore(_MemoryStore());
    final claims = base64Url
        .encode(utf8.encode(jsonEncode({'sub': 'synthetic-device-user'})))
        .replaceAll('=', '');
    await sessions.saveSession(
        accessToken: 'fixture.$claims.fixture',
        refreshToken: 'synthetic-never-network',
        matrixUserId: '@fixture:invalid');
    final client = MockClient((request) async {
      expect(request.url.host == 'payment-pin.invalid', isTrue,
          reason: 'Only the isolated transport may be called.');
      final body = request.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path == '/api/v1/payment-pin/status') {
        expect(request.method, 'GET');
        return http.Response(jsonEncode({'configured': configured}), 200);
      }
      if (request.url.path == '/api/v1/payment-pin/setup') {
        setupCalls++;
        expect(request.method, 'POST');
        expect(
            body.length == 2 &&
                body['pin'] == pin &&
                body['login_password'] == password,
            isTrue,
            reason:
                'Setup serializer must preserve the six-digit credential and login confirmation.');
        expect(request.headers['idempotency-key'] == 'fixture-setup', isTrue);
        configured = true;
        return http.Response('{"configured":true}', 200);
      }
      if (request.url.path == '/api/v1/payment-pin/authorize') {
        authorizationCalls++;
        final action = body['action'] as String;
        expect(body.length == 4, isTrue);
        expect(body['idempotency_key'] == operationKeys[action], isTrue,
            reason: 'Authorization binds the business idempotency key.');
        expect((request.headers['idempotency-key'] ?? '').isNotEmpty, isTrue);
        final payload = body['payload'] as Map<String, dynamic>;
        expect(
            jsonEncode(payload) ==
                jsonEncode(action == 'chat_transfer.create'
                    ? {
                        'receiver_id': 'synthetic-peer',
                        'amount': '1.00',
                        'note': null,
                        'room_id': null
                      }
                    : {
                        'mode': 'EQUAL',
                        'total': '1.00',
                        'share_count': 1,
                        'room_id': '!synthetic:invalid'
                      }),
            isTrue,
            reason: 'Authorization retains the exact business payload.');
        if (body['pin'] != pin) {
          return http.Response(
              jsonEncode({
                'error': {
                  'code': 'PAYMENT_PIN_INCORRECT',
                  'message': '支付密码不正确，还可尝试4次'
                }
              }),
              403,
              headers: {'content-type': 'application/json; charset=utf-8'});
        }
        checkedActions.add(action);
        return http.Response(
            '{"authorization":"synthetic-proof-never-valid"}', 200);
      }
      fail('Unexpected endpoint in isolated payment fixture');
    });
    addTearDown(client.close);
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://payment-pin.invalid'),
        sessionStore: sessions,
        client: client);
    final scope = await api.walletIntentScope();
    expect(
        (await api.paymentPinStatus(expectedWalletScope: scope))['configured'],
        false);

    bool? setupResult;
    String? authorizationResult;
    Future<void> setup() async {
      final context =
          tester.element(find.byKey(const ValueKey('fixture-home')));
      setupResult = await showPaymentPinSetup(context,
          isScopeCurrent: () async => await api.walletIntentScope() == scope,
          onSetup: (value, login) async {
            await api.setupPaymentPin(
                pin: value,
                loginPassword: login,
                idempotencyKey: 'fixture-setup',
                expectedWalletScope: scope);
          });
    }

    await tester.pumpWidget(CupertinoApp(
        home: CupertinoPageScaffold(
      child: Center(
          key: const ValueKey('fixture-home'),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('支付密码 · 隔离功能验证'),
            const Text('仅合成账号及内存接口，无真实资金'),
            CupertinoButton(onPressed: setup, child: const Text('开始设置')),
          ])),
    )));
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();
    await screenshot(tester, '01-login-confirmation');
    await tester.enterText(
        find.byKey(const ValueKey('payment-login-password')), password);
    await tester.pump();
    await confirm(tester);
    await digits(tester, pin);
    await screenshot(tester, '02-six-digit-setup');
    await confirm(tester);
    await digits(tester, '654321');
    await confirm(tester);
    expect(find.text('两次密码不一致，请重新输入'), findsOneWidget);
    expect(setupCalls, 0);
    await screenshot(tester, '03-setup-mismatch');
    await digits(tester, pin);
    await confirm(tester);
    expect(setupResult, true);
    expect(setupCalls, 1);
    expect(
        (await api.paymentPinStatus(expectedWalletScope: scope))['configured'],
        true);

    for (final action in ['chat_transfer.create', 'red_packet.create']) {
      operationKeys[action] = 'fixture-$action';
      final context =
          tester.element(find.byKey(const ValueKey('fixture-home')));
      final future = showPaymentPinAuthorization(context,
          title: action == 'chat_transfer.create' ? '确认转账' : '发红包',
          recipient: action == 'chat_transfer.create' ? '隔离测试好友' : '隔离测试群',
          amount: '1.00 点钻',
          fee: action == 'chat_transfer.create' ? '手续费 0.01 点钻' : null,
          isScopeCurrent: () async => await api.walletIntentScope() == scope,
          onAuthorize: (value) async {
            try {
              final result = await api.authorizePaymentPin(
                  pin: value,
                  action: action,
                  payload: action == 'chat_transfer.create'
                      ? {
                          'receiver_id': 'synthetic-peer',
                          'amount': '1.00',
                          'note': null,
                          'room_id': null
                        }
                      : {
                          'mode': 'EQUAL',
                          'total': '1.00',
                          'share_count': 1,
                          'room_id': '!synthetic:invalid'
                        },
                  idempotencyKey: operationKeys[action]!,
                  expectedWalletScope: scope);
              return result['authorization'] as String;
            } on BusinessApiException catch (error) {
              throw PaymentPinException(error.message);
            }
          });
      await tester.pumpAndSettle();
      await digits(tester, '123');
      await key(tester, 'delete');
      expect(find.text('●'), findsNWidgets(2));
      await key(tester, 'clear');
      expect(find.text('●'), findsNothing);
      await digits(tester, '12345');
      final before = authorizationCalls;
      await confirm(tester);
      expect(authorizationCalls, before);
      await digits(tester, '67');
      expect(find.text('●'), findsNWidgets(6));
      expect(authorizationCalls, before);
      await confirm(tester);
      expect(find.text('支付密码不正确，还可尝试4次'), findsOneWidget);
      expect(find.text('●'), findsNothing);
      await screenshot(
          tester,
          action == 'chat_transfer.create'
              ? '04-transfer-error'
              : '06-redpacket-error');
      await digits(tester, pin);
      await screenshot(
          tester,
          action == 'chat_transfer.create'
              ? '05-transfer-confirmation'
              : '07-redpacket-confirmation');
      await confirm(tester);
      authorizationResult = await future;
      expect(authorizationResult != null, isTrue);
    }
    expect(checkedActions.length, 2);
    expect(authorizationCalls, 4);
    await tester.tap(find.text('开始设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(setupResult, false);
    expect(setupCalls, 1);
    await screenshot(tester, '08-isolated-complete');
    binding.reportData = {
      'isolation': 'MockClient + in-memory session; no production or funds',
      'setup_requests': setupCalls,
      'authorization_requests': authorizationCalls,
      'verified_purposes': checkedActions,
      'screenshots': binding.reportData?['screenshots']
    };
  });
}
