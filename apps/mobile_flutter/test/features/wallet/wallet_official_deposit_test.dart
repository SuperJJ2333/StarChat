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
import 'package:liuhetong_mobile/features/wallet/wallet_page.dart';

import 'wallet_page_audit_test.dart' show MemoryStore;

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
      return jsonResponse(depositBody());
    });
    expect((await api.walletDepositAddress())['address'], syntheticAddress());
  });

  testWidgets(
      'funds closed still shows official address notice raw QR and exact clipboard',
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
    final api = await client((request) async => jsonResponse(
        request.url.path.endsWith('deposit-address') ? depositBody() : {}));
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取充值地址'));
    await tester.pumpAndSettle();
    expect(find.text(syntheticAddress()), findsOneWidget);
    expect(find.text(depositBody()['notice'] as String), findsOneWidget);
    expect(find.text('已生成专属充值地址'), findsNothing);
    final actual = tester
        .widget<CustomPaint>(find.descendant(
            of: find.byKey(const Key('wallet-deposit-qr')),
            matching: find.byWidgetPredicate((widget) =>
                widget is CustomPaint && widget.painter is QrPainter)))
        .painter as QrPainter;
    await tester.runAsync(() async {
      final expected = QrPainter(
          data: syntheticAddress(), version: QrVersions.auto, gapless: true);
      expect((await actual.toImageData(180))!.buffer.asUint8List(),
          (await expected.toImageData(180))!.buffer.asUint8List());
    });
    await tester.ensureVisible(find.byKey(const Key('wallet-deposit-copy')));
    await tester.tap(find.byKey(const Key('wallet-deposit-copy')));
    await tester.pumpAndSettle();
    expect(copied, syntheticAddress());
  });

  testWidgets(
      'loading prevents duplicates and failed refresh clears previous address',
      (tester) async {
    var calls = 0;
    final pending = Completer<http.Response>();
    final api = await client((request) async {
      if (!request.url.path.endsWith('deposit-address')) {
        return jsonResponse({});
      }
      calls++;
      return calls == 1 ? jsonResponse(depositBody()) : pending.future;
    });
    await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取充值地址'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('获取充值地址'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('wallet-deposit-load')));
    await tester.pump();
    expect(calls, 2);
    expect(find.byKey(const Key('wallet-deposit-loading')), findsOneWidget);
    expect(find.byKey(const Key('wallet-deposit-address')), findsNothing);
    expect(find.byKey(const Key('wallet-deposit-qr')), findsNothing);
    pending.complete(jsonResponse({
      'error': {
        'code': 'OFFICIAL_ADDRESS_NOT_CONFIGURED',
        'message': '官方充值地址尚未配置，请联系管理员'
      }
    }, 503));
    await tester.pumpAndSettle();
    expect(find.text('官方充值地址尚未配置，请联系管理员'), findsOneWidget);
    expect(find.byKey(const Key('wallet-deposit-copy')), findsNothing);
  });

  for (final bad in [
    '',
    'T${'2' * 33}',
    'https://invalid.example',
    ' ${syntheticAddress()}'
  ]) {
    testWidgets('invalid address rejected without QR: ${bad.length}',
        (tester) async {
      final api = await client((request) async => jsonResponse(
          request.url.path.endsWith('deposit-address')
              ? {...depositBody(), 'address': bad}
              : {}));
      await tester.pumpWidget(CupertinoApp(home: WalletPage(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('获取充值地址'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('wallet-deposit-address')), findsNothing);
      expect(find.byKey(const Key('wallet-deposit-qr')), findsNothing);
      expect(find.text('充值地址数据无效，请联系管理员'), findsOneWidget);
    });
  }
}
