import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/chat_payment_intent.dart';
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

void main() {
  test(
      'lost create response retries same intent and changed amount reauthorizes',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'x.${base64Url.encode(utf8.encode('{"sub":"alice"}'))}.x',
        refreshToken: 'test');
    final keys = <String>[];
    var calls = 0;
    var prompts = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          keys.add(request.headers['Idempotency-Key']!);
          if (++calls == 1) {
            throw http.ClientException('synthetic lost response');
          }
          return http.Response('{"id":"created"}', 201);
        }));
    final intent = ChatPaymentIntent(
        api: api,
        scope: await api.walletIntentScope(),
        authorize: (action, payload, key) async {
          prompts++;
          return 'proof';
        });
    final body = <String, dynamic>{'receiver_id': 'bob', 'amount': '1.00'};
    await expectLater(intent.create('chat_transfer.create', body),
        throwsA(isA<http.ClientException>()));
    await intent.create('chat_transfer.create', body);
    expect(keys[0], keys[1]);
    expect(prompts, 1);
    await intent.create('chat_transfer.create', {...body, 'amount': '2.00'});
    expect(keys[2], isNot(keys[1]));
    expect(prompts, 2);
    await intent.create('chat_transfer.create', body);
    expect(keys[3], keys[0],
        reason: 'editing away and back must not repeat an uncertain debit');
    await intent.create('chat_transfer.create', {...body, 'amount': '01.0'});
    expect(keys[4], keys[0],
        reason: 'equivalent decimal spelling is the same payment intent');
  });
  test('cancel never sends a financial request', () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'x.${base64Url.encode(utf8.encode('{"sub":"alice"}'))}.x',
        refreshToken: 'test');
    var calls = 0;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }));
    final intent = ChatPaymentIntent(
        api: api,
        scope: await api.walletIntentScope(),
        authorize: (_, __, ___) async => null);
    await expectLater(intent.create('red_packet.create', {'total': '1.00'}),
        throwsA(isA<ChatPaymentCancelled>()));
    expect(calls, 0);
  });
}
