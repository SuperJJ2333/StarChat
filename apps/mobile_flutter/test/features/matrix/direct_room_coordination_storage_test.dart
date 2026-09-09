import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/direct_room_coordination_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('intent survives recreation and remains isolated by account and peer',
      () async {
    final first = PreferencesDirectRoomIntentStore('@a:test');
    final intent = await first.loadOrCreate('b');
    await first.saveRoom('b', intent, '!room:test');
    final restarted = PreferencesDirectRoomIntentStore('@a:test');
    final restored = await restarted.loadOrCreate('b');
    expect(restored.attemptId, intent.attemptId);
    expect(restored.roomId, '!room:test');
    expect(
        (await restarted.loadOrCreate('c')).attemptId, isNot(intent.attemptId));
    expect(
        (await PreferencesDirectRoomIntentStore('@other:test')
                .loadOrCreate('b'))
            .attemptId,
        isNot(intent.attemptId));
  });

  test('corrupt intent is never silently replaced with fresh creation intent',
      () async {
    SharedPreferences.setMockInitialValues({
      'direct-room-intent-v1:%40a%3Atest:b': '{broken',
    });
    await expectLater(
        PreferencesDirectRoomIntentStore('@a:test').loadOrCreate('b'),
        throwsFormatException);
    await expectLater(PreferencesDirectRoomIntentStore('').loadOrCreate('b'),
        throwsStateError);
  });

  test('transport carries stable owner attempt and requires complete responses',
      () async {
    final requests = <http.Request>[];
    var malformed = false;
    final api = BusinessApiClient(
      baseUri: Uri.parse('https://example.test'),
      sessionStore: SecureSessionStore(),
      client: MockClient((request) async {
        requests.add(request);
        final Object body = malformed
            ? {}
            : switch (request.url.path) {
                '/api/v1/direct-conversations/claim' => {
                    'matrix_room_id': null,
                    'may_create': true,
                    'can_publish': true
                  },
                '/api/v1/direct-conversations/publish' => {
                    'matrix_room_id': '!one:test'
                  },
                _ => {'matrix_room_id': null},
              };
        return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    final coordinator = ApiDirectRoomCoordinator(api);
    expect(await coordinator.canonicalRoomId('b'), isNull);
    expect((await coordinator.claim('b', 'attempt')).mayCreate, isTrue);
    expect(await coordinator.publish('b', 'attempt', '!one:test'), '!one:test');
    expect(jsonDecode(requests[1].body),
        {'peer_user_id': 'b', 'attempt_id': 'attempt'});
    expect(jsonDecode(requests[2].body)['attempt_id'], 'attempt');
    expect(requests[1].headers['Idempotency-Key'], 'attempt');
    malformed = true;
    await expectLater(coordinator.canonicalRoomId('b'), throwsStateError);
    await expectLater(coordinator.claim('b', 'attempt'), throwsStateError);
    await expectLater(
        coordinator.publish('b', 'attempt', '!one:test'), throwsStateError);
  });
}
