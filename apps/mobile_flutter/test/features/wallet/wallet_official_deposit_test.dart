import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';

import 'wallet_page_audit_test.dart' show MemoryStore;
import 'manual_wallet_api_test.dart' as fixtures;
import 'manual_wallet_flow_test.dart' as flow;

// Synthetic address: deterministic bytes, no private key or real wallet.
String syntheticAddress() {
  final payload = [0x41, ...List<int>.generate(20, (i) => i + 1)];
  final bytes = [
    ...payload,
    ...sha256.convert(sha256.convert(payload).bytes).bytes.take(4)
  ];
  var number = bytes.fold(
      BigInt.zero, (value, byte) => (value << 8) + BigInt.from(byte));
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var result = '';
  while (number > BigInt.zero) {
    result = alphabet[(number % BigInt.from(58)).toInt()] + result;
    number ~/= BigInt.from(58);
  }
  return result;
}

http.Response jsonResponse(Object data, [int status = 200]) =>
    http.Response(jsonEncode(data), status,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> depositBody() => {
      ...fixtures.intent,
      'source_address': 'source',
      'official_address': syntheticAddress(),
      'expires_at': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    };

Map<String, dynamic> officialAddressBody() => {
      'address': syntheticAddress(),
      'asset': 'USDT',
      'network': 'TRC20',
      'minimum_deposit': '10.000000',
      'funding_enabled': false,
      'notice': '当前仅展示官方地址，充值入账暂未开放，请勿转账。'
    };

Future<BusinessApiClient> client(
    Future<http.Response> Function(http.Request) handle) async {
  final store = SecureSessionStore(MemoryStore());
  await store.saveSession(
      accessToken: 'e30.eyJzdWIiOiJ3YWxsZXQtdGVzdCJ9.test',
      refreshToken: 'refresh');
  return BusinessApiClient(
      baseUri: Uri.parse('https://business.example'),
      sessionStore: store,
      client: MockClient(handle));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('deposit address uses authenticated read-only official route', () async {
    final api = await client((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/wallet/official-deposit-address');
      expect(request.headers['authorization'], startsWith('Bearer '));
      return jsonResponse(officialAddressBody());
    });
    expect((await api.walletDepositAddress())['address'], syntheticAddress());
  });

  testWidgets(
      'open deposit intent shows a validated official QR and exact clipboard',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final api = await flow.client(
        (request) async => flow.json(request.url.path.endsWith('/binding')
            ? fixtures.binding
            : request.method == 'POST'
                ? depositBody()
                : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    expect(find.text(syntheticAddress()), findsOneWidget);
    final actual = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byKey(const Key('manual-deposit-qr')),
            matching: find.byWidgetPredicate((widget) =>
                widget is CustomPaint && widget.painter is QrPainter)))
        .painter as QrPainter;
    await tester.runAsync(() async {
      final expected = QrPainter(
          data: syntheticAddress(), version: QrVersions.auto, gapless: true);
      expect((await actual.toImageData(180))!.buffer.asUint8List(),
          (await expected.toImageData(180))!.buffer.asUint8List());
    });
    await tester.ensureVisible(find.byKey(const Key('manual-official-copy')));
    await tester.tap(find.byKey(const Key('manual-official-copy')));
    await tester.pumpAndSettle();
    expect(copied, syntheticAddress());
  });

  testWidgets(
      'failed intent refresh clears old official QR while retaining recovery',
      (tester) async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final api = await flow.client((request) async {
      if (request.url.path.endsWith('/binding')) {
        return flow.json(fixtures.binding);
      }
      if (request.method == 'POST') {
        return flow.json(depositBody());
      }
      calls++;
      return pending.future;
    });
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await flow.openDeposit(tester);
    await tester.enterText(
        find.byKey(const Key('manual-deposit-amount')), '10');
    await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
    final store = ManualOperationStore(api);
    await store.initialize();
    final original = await store.read('deposit');
    await tester.tap(find.byKey(const Key('manual-refresh')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('manual-refresh')));
    await tester.pump();
    expect(calls, 1);
    expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
    pending.complete(jsonResponse({
      'error': {
        'code': 'OFFICIAL_ADDRESS_NOT_CONFIGURED',
        'message': '官方充值地址尚未配置，请联系管理员'
      }
    }, 503));
    await tester.pumpAndSettle();
    expect(find.textContaining('官方充值地址尚未配置，请联系管理员'), findsOneWidget);
    expect(find.byKey(const Key('manual-official-copy')), findsNothing);
    final recovery = await store.read('deposit');
    expect(recovery?['id'], 'intent');
    expect(recovery?['key'], original?['key']);
  });

  for (final bad in [
    '',
    'T${'2' * 33}',
    'https://invalid.example',
    ' ${syntheticAddress()}'
  ]) {
    testWidgets('invalid address rejected without QR: ${bad.length}',
        (tester) async {
      final api = await flow.client(
          (request) async => flow.json(request.url.path.endsWith('/binding')
              ? fixtures.binding
              : request.method == 'POST'
                  ? {...depositBody(), 'official_address': bad}
                  : {}));
      await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
      await tester.pumpAndSettle();
      await flow.openDeposit(tester);
      await tester.enterText(
          find.byKey(const Key('manual-deposit-amount')), '10');
      await flow.tap(tester, find.byKey(const Key('manual-deposit-create')));
      expect(find.byKey(const Key('manual-official-copy')), findsNothing);
      expect(find.byKey(const Key('manual-deposit-qr')), findsNothing);
      expect(find.text('充值地址数据无效，请联系管理员'), findsOneWidget);
      if (bad.isNotEmpty) expect(find.text(bad), findsNothing);
    });
  }
}
