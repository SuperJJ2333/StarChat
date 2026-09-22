import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'business_phone_client_test.dart' show MemoryStore;

void main() {
  for (final body in [
    '<html>not found</html>',
    '[]',
    '{"detail":"Not Found"}'
  ]) {
    test(
        'route missing keeps HTTP status without exposing server content: $body',
        () async {
      final store = SecureSessionStore(MemoryStore());
      await store.saveSession(accessToken: 'a', refreshToken: 'b');
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://test.invalid'),
          sessionStore: store,
          client: MockClient((_) async => http.Response(body, 404)));
      await expectLater(
          api.rebindOldRequest(),
          throwsA(isA<BusinessApiException>()
              .having((e) => e.statusCode, 'status', 404)
              .having(
                  (e) => e.message, 'safe text', isNot(contains('<html>')))));
    });
  }
}
