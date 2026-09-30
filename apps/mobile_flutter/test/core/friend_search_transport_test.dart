import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'business_api_session_test.dart' show MemoryStore;

void main() {
  test('friend search keeps all identifiers out of the request URL', () async {
    final store = SecureSessionStore(MemoryStore());
    await store.saveSession(
        accessToken: 'test-token', refreshToken: 'test-refresh');
    final requests = <http.Request>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{"items":[]}', 200);
        }));
    for (final query in [
      'friend@example.invalid',
      '+8613800000001',
      'a1111144'
    ]) {
      expect(await api.searchUsers(query), {'items': []});
      final request = requests.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/users/search');
      expect(request.url.query, isEmpty);
      expect(jsonDecode(request.body), {'q': query});
      expect(request.headers['Authorization'], 'Bearer test-token');
    }
    expect(requests.length, 3);
  });
}
