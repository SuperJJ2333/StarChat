import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

class _Memory implements SecureKeyValueStore {
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

String _token(String user) => 'x.${base64Url.encode(utf8.encode(jsonEncode({
          'sub': user,
          'sid': 'session-a'
        })))}.x';

void main() {
  test(
      'session replacement discards a late payment response for the same account',
      () async {
    final store = SecureSessionStore(_Memory());
    String sessionToken(String family) =>
        'x.${base64Url.encode(utf8.encode(jsonEncode({
              'sub': 'alice',
              'family_id': family,
              'device_id': 'device'
            })))}.x';
    await store.saveSession(
        accessToken: sessionToken('original'), refreshToken: 'test');
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          calls++;
          await store.saveSession(
              accessToken: sessionToken('replacement'),
              refreshToken: 'test-new');
          return http.Response('{"authorization":"synthetic-proof"}', 200);
        }));
    final account = await api.walletIntentScope();
    final session = await api.paymentIntentScope();
    await expectLater(
        api.authorizePaymentPin(
            pin: '012345',
            action: 'chat_transfer.create',
            payload: {'receiver_id': 'bob', 'amount': '1.00'},
            idempotencyKey: 'key',
            expectedWalletScope: account,
            expectedPaymentScope: session),
        throwsStateError);
    await expectLater(
        api.setupPaymentPin(
            pin: '012345',
            loginPassword: 'synthetic-login',
            idempotencyKey: 'setup',
            expectedWalletScope: account,
            expectedPaymentScope: session),
        throwsStateError);
    expect(calls, 1);
  });
  test('PIN and fixed business intent travel in bodies with account guard',
      () async {
    final storage = _Memory();
    final store = SecureSessionStore(storage);
    await store.saveSession(accessToken: _token('alice'), refreshToken: 'test');
    final requests = <http.Request>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((r) async {
          requests.add(r);
          return http.Response(
              jsonEncode({
                'configured': true,
                'authorization': 'test-proof',
                'id': 'created'
              }),
              200);
        }));
    final scope = await api.walletIntentScope();
    await api.paymentPinStatus(expectedWalletScope: scope);
    await api.setupPaymentPin(
        pin: '012345',
        loginPassword: 'synthetic-login',
        idempotencyKey: 'setup-key',
        expectedWalletScope: scope);
    await api.authorizePaymentPin(
        pin: '012345',
        action: 'chat_transfer.create',
        payload: {'receiver_id': 'bob', 'amount': '1.00'},
        idempotencyKey: 'intent-key',
        expectedWalletScope: scope);
    await api.createChatTransfer(
        receiverId: 'bob',
        amount: '1.00',
        idempotencyKey: 'intent-key',
        paymentAuthorization: 'test-proof',
        expectedWalletScope: scope);
    expect(requests.map((r) => r.url.path).toList(), [
      '/api/v1/payment-pin/status',
      '/api/v1/payment-pin/setup',
      '/api/v1/payment-pin/authorize',
      '/api/v1/chat-transfers'
    ]);
    expect(jsonDecode(requests[1].body)['pin'], '012345');
    expect(jsonDecode(requests[2].body)['idempotency_key'], 'intent-key');
    expect(requests[3].headers['Idempotency-Key'], 'intent-key');
    expect(jsonDecode(requests[3].body)['payment_authorization'], 'test-proof');
    expect(requests.every((r) => !r.url.toString().contains('012345')), true);
    expect(
        storage.values.values.any((value) => value.contains('012345')), false);
    await store.saveSession(
        accessToken: _token('other'), refreshToken: 'test-other');
    await expectLater(
        api.setupPaymentPin(
            pin: '012345',
            loginPassword: 'synthetic-login',
            idempotencyKey: 'setup-key',
            expectedWalletScope: scope),
        throwsStateError);
    expect(requests.length, 4);
  });
  test('red packet create retains authorized destination and idempotency',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(accessToken: _token('alice'), refreshToken: 'test');
    late http.Request request;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((r) async {
          request = r;
          return http.Response('{"id":"packet"}', 201);
        }));
    await api.createRedPacket(
        mode: 'EXCLUSIVE',
        total: '1.00',
        shareCount: 1,
        roomId: '!test',
        recipientId: 'bob',
        idempotencyKey: 'packet-key',
        paymentAuthorization: 'packet-proof',
        expectedWalletScope: await api.walletIntentScope());
    expect(jsonDecode(request.body), {
      'mode': 'EXCLUSIVE',
      'total': '1.00',
      'share_count': 1,
      'room_id': '!test',
      'recipient_id': 'bob',
      'payment_authorization': 'packet-proof'
    });
    expect(request.headers['Idempotency-Key'], 'packet-key');
  });
}
