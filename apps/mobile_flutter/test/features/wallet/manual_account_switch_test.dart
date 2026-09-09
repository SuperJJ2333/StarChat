import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/features/wallet/manual_operation_store.dart';
import 'package:liuhetong_mobile/features/wallet/manual_wallet_api.dart';
import 'manual_wallet_flow_test.dart' as flow;

void main() {
  test('prepared wallet request cannot use a newly switched account', () async {
    SharedPreferences.setMockInitialValues({});
    var sends = 0;
    final client = await flow.client((request) async {
      sends++;
      return flow.json({});
    });
    final store = ManualOperationStore(client);
    final api = ManualWalletApi(client);
    await store.initialize();
    final operation =
        await store.begin('binding', {'address': 'synthetic', 'version': 0});
    await client.sessionStore.saveSession(
        accessToken: 'e30.eyJzdWIiOiJib2IifQ.test', refreshToken: 'refresh');
    await expectLater(
        api.createBindingChallenge(
            address: operation['address'],
            expectedVersion: operation['version'],
            idempotencyKey: operation['key']),
        throwsStateError);
    expect(sends, 0);
  });
  test('refresh retry cannot switch a wallet request subject', () async {
    var sends = 0;
    final client = await flow.client((request) async {
      if (request.url.path.endsWith('/auth/refresh')) {
        return flow.json({
          'access_token': 'e30.eyJzdWIiOiJib2IifQ.test',
          'refresh_token': 'next'
        });
      }
      sends++;
      return http.Response('{}', 401);
    });
    final api = ManualWalletApi(client);
    await expectLater(
        api.createBindingChallenge(
            address: 'synthetic',
            expectedVersion: 0,
            idempotencyKey: 'original-key'),
        throwsStateError);
    expect(sends, 1);
  });
}
