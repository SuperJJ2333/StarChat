import 'dart:convert';

import 'package:liuhetong_mobile/features/profile/profile_controller.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

final class _Store implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  final gif = Uint8List.fromList(
      base64Decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'));
  for (final port in ['avatar', 'comment', 'cover']) {
    for (final replacement in ['revoke', 'direct-store']) {
      test(
          '$port retains originating session across GIF validation $replacement',
          () async {
        final sessions = SecureSessionStore(_Store());
        // Avatar authorization must work without a Matrix identity as before.
        await sessions.saveSession(
            accessToken: 'origin-access', refreshToken: 'origin-refresh');
        final requests = <http.Request>[];
        final api = BusinessApiClient(
            baseUri: Uri.parse('https://example.test'),
            sessionStore: sessions,
            client: MockClient((request) async {
              requests.add(request);
              return http.Response('', 204);
            }));
        Future<void> put() => switch (port) {
              'avatar' => api.putAvatar(
                  const AvatarUploadSession(
                      uploadId: 'upload-1', uploadUrl: '/avatar-content'),
                  AvatarCandidate(bytes: gif, mimeType: 'image/gif')),
              'comment' => api.putMomentUpload('upload-1', gif, 'image/gif'),
              _ => api.putMomentCoverUpload('upload-1', gif, 'image/gif'),
            };
        // Prove the actual GIF passes asynchronous validation and reaches PUT.
        await put();
        expect(
            requests.single.headers['Authorization'], 'Bearer origin-access');
        requests.clear();
        final pending = put();
        final rejected = expectLater(
            pending,
            throwsA(isA<BusinessApiException>()
                .having((error) => error.code, 'code', 'AUTH_SESSION_ENDED')));
        // Settle session-read microtasks without releasing the event queue:
        // the real GIF compute isolate is still awaiting its return event.
        for (var i = 0; i < 8; i++) {
          await Future<void>.value();
        }
        expect(requests, isEmpty);
        if (replacement == 'revoke') await api.clearLocalSession();
        await sessions.saveSession(
            accessToken: 'replacement-access',
            refreshToken: 'replacement-refresh',
            matrixUserId: '@b:example.test');
        await rejected;
        expect(requests, isEmpty,
            reason:
                'validation must not dispatch under replacement credentials');
        // This is a populated new session, not an empty-session rejection.
        expect((await sessions.session())?.accessToken, 'replacement-access');
      });
    }
  }
  test('avatar GIF validation accepts trusted refresh lineage', () async {
    final sessions = SecureSessionStore(_Store());
    await sessions.saveSession(
        accessToken: 'origin', refreshToken: 'origin-refresh');
    final putTokens = <String?>[];
    final api = BusinessApiClient(
        baseUri: Uri.parse('https://example.test'),
        sessionStore: sessions,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/refresh')) {
            return http.Response(
                '{"access_token":"refreshed","refresh_token":"refreshed-r"}',
                200);
          }
          putTokens.add(request.headers['Authorization']);
          return http.Response('', 204);
        }));
    final pending = api.putAvatar(
        const AvatarUploadSession(
            uploadId: 'upload', uploadUrl: '/avatar-content'),
        AvatarCandidate(bytes: gif, mimeType: 'image/gif'));
    for (var i = 0; i < 8; i++) {
      await Future<void>.value();
    }
    expect(putTokens, isEmpty);
    await api.refreshSession();
    expect(putTokens, isEmpty,
        reason: 'real validation await spans trusted refresh');
    await pending;
    expect(putTokens, ['Bearer refreshed']);
  });
  for (final port in ['task', 'comment', 'cover']) {
    test('$port PUT rejects GIF declared JPEG before transport', () async {
      final sessions = SecureSessionStore(_Store());
      await sessions.saveSession(
          accessToken: 'test-access',
          refreshToken: 'test-refresh',
          matrixUserId: '@a:example.test');
      var puts = 0;
      final api = BusinessApiClient(
          baseUri: Uri.parse('https://example.test'),
          sessionStore: sessions,
          client: MockClient((request) async {
            puts++;
            return http.Response('', 204);
          }));
      final lease = await api.captureMomentPublishSession();
      Future<void> put(String mime) => switch (port) {
            'task' => api.putMomentTask(lease, 'upload-1', gif, mime),
            'comment' => api.putMomentUpload('upload-1', gif, mime),
            _ => api.putMomentCoverUpload('upload-1', gif, mime),
          };
      await expectLater(put('image/jpeg'), throwsA(isA<FormatException>()));
      expect(puts, 0, reason: 'begin declaration must not be silently changed');
      await put('image/gif');
      expect(puts, 1);
    });
  }
}
