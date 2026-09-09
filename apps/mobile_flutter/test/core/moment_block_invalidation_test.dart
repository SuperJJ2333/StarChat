import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/moments/moments_privacy_changes.dart';

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
      'successful block invalidates visible Moments; rejected block preserves them',
      () async {
    final store = SecureSessionStore(_Memory());
    await store.saveSession(
        accessToken: 'test-token', refreshToken: 'test-refresh');
    var responseCode = 200;
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://business.example'),
        sessionStore: store,
        client: MockClient((request) async {
          expect(request.url.path, endsWith('/blocks'));
          return http.Response('{}', responseCode,
              headers: {'content-type': 'application/json'});
        }));
    var invalidations = 0;
    void changed() {
      invalidations++;
    }

    momentsPrivacyChanges.addListener(changed);
    addTearDown(() => momentsPrivacyChanges.removeListener(changed));
    await api.blockContact('friend');
    expect(invalidations, 1);
    responseCode = 500;
    await expectLater(
        api.blockUser('other'), throwsA(isA<BusinessApiException>()));
    expect(invalidations, 1);
  });
}
