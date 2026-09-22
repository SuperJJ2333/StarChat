import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'business_phone_client_test.dart' show MemoryStore;

void main() {
  test(
      'ownership transfer resolves business identity and preserves key across clients',
      () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'test-access', refreshToken: 'test-refresh');
    final keys = <String>[];
    String tenure = '2026-08-01T00:00:00Z';
    final httpClient = MockClient((r) async {
      if (r.url.path.endsWith('/owner')) {
        return http.Response(
            jsonEncode({'owner_user_id': 'old', 'owner_since': tenure}), 200);
      }
      if (r.url.path.endsWith('/users/lookup')) {
        expect(r.url.queryParameters['matrix_user_id'], '@next:test');
        return http.Response('{"user_id":"next-business"}', 200);
      }
      expect(r.url.path, contains('/transfer-owner'));
      expect(jsonDecode(r.body), {'new_owner_user_id': 'next-business'});
      keys.add(r.headers['Idempotency-Key']!);
      return http.Response('{"stage":"NEEDS_REVIEW"}', 200);
    });
    BusinessApiClient make() => BusinessApiClient(
        baseUri: Uri.parse('https://api.test'),
        sessionStore: store,
        client: httpClient);
    expect(
        (await make().requestGroupOwnershipTransfer(
            '!room:test', '@next:test'))['stage'],
        'NEEDS_REVIEW');
    await make().requestGroupOwnershipTransfer('!room:test', '@next:test');
    expect(keys[0], keys[1]);
    tenure = '2026-09-01T00:00:00Z';
    await make().requestGroupOwnershipTransfer('!room:test', '@next:test');
    expect(keys.last, isNot(keys.first));
  });
}
