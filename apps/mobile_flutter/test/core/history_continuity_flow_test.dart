import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/business_api_client.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_bootstrap_controller.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alice = '@synthetic-alice:example.test';
const _bob = '@synthetic-bob:example.test';

// Real application services, synthetic HTTP, and a Matrix boundary spy.
// Service reconstruction is not an OS restart or SQLCipher decryption test.
final class _Storage implements SecureKeyValueStore {
  final values = <String, String>{};
  final deleted = <String>[];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    values.remove(key);
  }
}

final class _Matrix implements MatrixSessionGateway, MatrixTokenLoginGateway {
  _Matrix(this.store);
  final SecureSessionStore store;
  @override
  bool isLoggedIn = true;
  @override
  bool credentialsInvalid = false;
  @override
  String? userId = _alice;
  @override
  String? deviceId = 'SYNTHETIC-DEVICE';
  String? errorCode;
  int clears = 0, syncs = 0, suspends = 0;
  final loginDevices = <String?>[];
  @override
  Future<void> sync() async {
    syncs++;
    if (errorCode case final code?) {
      credentialsInvalid = true;
      throw MatrixException.fromJson({'errcode': code, 'error': 'synthetic'});
    }
  }

  @override
  Future<void> suspend() async => suspends++;
  @override
  Future<void> clearLocalChatData() async {
    clears++;
    await store.clearMatrixIdentity();
    isLoggedIn = false;
    userId = null;
    deviceId = null;
  }

  @override
  Future<void> loginWithToken(
      {required String loginToken,
      required Uri homeserver,
      String? deviceId}) async {
    loginDevices.add(deviceId);
    credentialsInvalid = false;
    errorCode = null;
  }
}

final class _Fixture {
  final storage = _Storage();
  late final store = SecureSessionStore(storage);
  late final matrix = _Matrix(store);
  String loginIdentity = _alice;
  int refreshStatus = 200;
  final requests = <String>[];
  Map<String, String> preserved = {};
  Future<void> seed() async {
    await store.saveSession(
        accessToken: 'synthetic-access',
        refreshToken: 'synthetic-refresh',
        matrixUserId: _alice);
    await store.saveMatrixBinding(MatrixLocalBinding(
        version: 1,
        matrixUserId: _alice,
        deviceId: 'SYNTHETIC-DEVICE',
        homeserver: 'https://matrix.example.test',
        databaseGeneration: 'synthetic-generation'));
    await store.matrixDatabaseKey();
    await store.saveEncryptedRecoveryKey('synthetic-recovery');
    preserved = Map.of(storage.values)..remove('liuhetong.business_session.v1');
  }

  BusinessApiClient api() => BusinessApiClient(
        baseUri: Uri.parse('https://business.example.test'),
        sessionStore: SecureSessionStore(storage),
        client: MockClient((request) async {
          final path = request.url.path;
          requests.add(path);
          if (path.endsWith('/refresh') && refreshStatus != 200) {
            return http.Response(
                jsonEncode({
                  'error': {
                    'code': 'REFRESH_TOKEN_INVALID',
                    'message': 'synthetic rejection'
                  }
                }),
                refreshStatus);
          }
          final body = path.endsWith('/matrix-login-token')
              ? {
                  'login_token': 'synthetic-login',
                  'homeserver': 'https://matrix.example.test',
                  'expires_in': 60,
                  'matrix_user_id': loginIdentity
                }
              : {
                  'access_token': 'synthetic-next-access',
                  'refresh_token': 'synthetic-next-refresh',
                  'matrix_user_id': loginIdentity
                };
          return http.Response(jsonEncode(body), 200,
              headers: {'content-type': 'application/json'});
        }),
      );
  void expectPreserved() {
    for (final entry in preserved.entries) {
      expect(storage.values[entry.key] == entry.value, isTrue,
          reason: 'Retain Matrix material without exposing values');
      expect(storage.deleted.contains(entry.key), isFalse,
          reason: 'Do not delete and recreate Matrix material');
    }
    expect(matrix.clears, 0);
    expect(matrix.deviceId, 'SYNTHETIC-DEVICE');
  }

  SessionBootstrapController bootstrapper() {
    final controller =
        SessionBootstrapController(business: api(), matrix: matrix);
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> login() => DualDomainLoginService(
          business: api(),
          matrix: matrix,
          deviceKey: () => 'synthetic-device-key')
      .login('synthetic-user', 'synthetic-password');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('logout then reconstructed services lock history until same-user login',
      () async {
    final f = _Fixture();
    await f.seed();
    final before = f.bootstrapper();
    await before.bootstrap();
    expect(before.state.status, SessionBootstrapStatus.authenticated);
    await before.logout();
    expect(await f.store.session(), isNull);
    expect(before.canShowCachedMessages, isFalse);
    f.expectPreserved();
    final restarted = f.bootstrapper();
    final syncs = f.matrix.syncs;
    await restarted.bootstrap();
    expect(restarted.state.status, SessionBootstrapStatus.unauthenticated);
    expect(restarted.canShowCachedMessages, isFalse);
    expect(f.matrix.syncs, syncs);
    await f.login();
    await restarted.bootstrap();
    expect(restarted.state.status, SessionBootstrapStatus.authenticated);
    expect(f.matrix.loginDevices, isEmpty);
    expect(f.requests.where((p) => p.endsWith('/matrix-login-token')), isEmpty);
    f.expectPreserved();
  });
  for (final status in [401, 403]) {
    test(
        'business refresh $status locks retained history after service restart',
        () async {
      final f = _Fixture();
      await f.seed();
      f.refreshStatus = status;
      for (var restart = 0; restart < 2; restart++) {
        final controller = f.bootstrapper();
        await controller.bootstrap();
        expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
        expect(controller.canShowCachedMessages, isFalse);
        expect(await f.store.session(), isNull);
        f.expectPreserved();
      }
      expect(f.matrix.syncs, 0);
      expect(f.requests.where((p) => p.endsWith('/refresh')), hasLength(1));
    });
  }
  for (final code in ['M_UNKNOWN_TOKEN', 'M_FORBIDDEN']) {
    test('$code then same-device reauthentication retains Matrix material',
        () async {
      final f = _Fixture();
      await f.seed();
      f.matrix.errorCode = code;
      final controller = f.bootstrapper();
      await controller.bootstrap();
      expect(controller.state.status, SessionBootstrapStatus.unauthenticated);
      expect(controller.canShowCachedMessages, isFalse);
      expect(await f.store.session(), isNull);
      expect(f.matrix.suspends, 1);
      f.expectPreserved();
      await f.login();
      await controller.bootstrap();
      expect(controller.state.status, SessionBootstrapStatus.authenticated);
      expect(f.matrix.loginDevices, ['SYNTHETIC-DEVICE']);
      f.expectPreserved();
    });
  }
  test(
      'different-user login and service restart fail closed without confirmed clear',
      () async {
    final f = _Fixture();
    await f.seed();
    f.loginIdentity = _bob;
    await expectLater(f.login(), throwsA(isA<MatrixAccountSwitchRequired>()));
    final restarted = f.bootstrapper();
    await restarted.bootstrap();
    expect(restarted.state.status, SessionBootstrapStatus.fatalError);
    expect(restarted.canShowCachedMessages, isFalse);
    expect(f.matrix.syncs, 0);
    expect(f.matrix.loginDevices, isEmpty);
    f.expectPreserved();
  });
}
