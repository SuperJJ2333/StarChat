import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_watchdog.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_sync_recovery_controller.dart';
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;
import 'retained_device_reauthentication_test.dart'
    show RetainedEncryption, RetainedOlm;

class _ReadyClient extends LogoutTrackingClient {
  _ReadyClient(super.account)
      : super(
            loggedIn: true,
            matrixUserId: '@$account:synthetic.test',
            matrixDeviceId: 'device-$account');
  @override
  Future<void> get initializationCompleted => Future<void>.value();
}

class _RetainedOlm extends RetainedOlm {
  String? _device;
  @override
  String? get ourDeviceId => _device;
  @override
  set ourDeviceId(String? value) => _device = value;
}

class _BindingFailureClient extends _ReadyClient {
  _BindingFailureClient(super.account);
  @override
  Future<void> get initializationCompleted =>
      throw StateError('synthetic owner binding failure');
}

class _RetainedEncryption extends RetainedEncryption {
  final _olm = _RetainedOlm();
  @override
  _RetainedOlm get olmManager => _olm;
  @override
  bool get enabled => false;
  @override
  Future<void> dispose() async {}
}

/// Real SDK sync/init bookkeeping; only storage/transport and encryption are
/// fixtures. A stale HTTP response must not revoke freshly adopted credentials.
class _SyncClient extends Client {
  _SyncClient(http.Client transport)
      : super('switch-sync',
            httpClient: transport, preserveStoreOnInvalidToken: true) {
    homeserver = Uri.parse('https://synthetic.test');
    accessToken = 'synthetic-old-token';
    backgroundSync = false;
    syncErrorTimeoutSec = 0;
  }
  @override
  String get userID => '@retained:synthetic.test';
  @override
  String get deviceID => 'synthetic-device';
  @override
  bool isLogged() => accessToken != null;
  @override
  DatabaseApi? get database => null;
  @override
  final _RetainedEncryption encryption = _RetainedEncryption();
  @override
  Future<(DiscoveryInformation?, GetVersionsResponse, List<LoginFlow>)>
      checkHomeserver(Uri homeserverUrl,
              {bool checkWellKnown = true,
              Set<String>? overrideSupportedVersions}) async =>
          (null, GetVersionsResponse(versions: const []), const <LoginFlow>[]);
}

MatrixClientContinuityMetadata _metadata(Client client) =>
    MatrixClientContinuityMetadata(
        isLoggedIn: client.isLogged(),
        userId: client.userID,
        deviceId: client.deviceID,
        ed25519Fingerprint: 'synthetic-fingerprint-${client.userID}',
        databaseGeneration: 'synthetic-generation-${client.userID}');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('A to B to A binds a new unverified projection owner each time',
      () async {
    final secure = SecureSessionStore(MemorySecureKeyValueStore());
    final a = _ReadyClient('a');
    final b = _ReadyClient('b');
    final aAgain = _ReadyClient('a');
    final reopened = [b, aAgain];
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        suspendClient: (_) async {},
        selectClientAccount: (_, __) async {},
        resumeClient: () async => reopened.removeAt(0),
        readContinuityMetadata: (client) async => _metadata(client));
    var oldOwner = secure.startupProjectionCoordinator!;
    try {
      for (final target in [b, aAgain]) {
        final oldPermit = oldOwner.beginDisplayCapture()!;
        await matrix.selectAccount(
            target.userID!, Uri.parse('https://synthetic.test'));
        expect(oldOwner.isDisplayCurrent(oldPermit), isFalse);
        final current = secure.startupProjectionCoordinator;
        expect(current, isNotNull,
            reason: 'selected account needs its own live projection owner');
        expect(current, isNot(same(oldOwner)));
        expect(current!.canCapture, isFalse,
            reason: 'selection must not grant business-verified cache writes');
        expect(current.beginDisplayCapture(), isNotNull);
        current.markVerified();
        expect(current.beginCapture(), isNotNull,
            reason:
                'later authenticated capture must not keep a retired owner');
        oldOwner = current;
      }
    } finally {
      await matrix.suspend();
    }
  });

  test('overlapping retained logins serialize credential adoption', () async {
    final firstRequested = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final syncResponse = Completer<http.Response>();
    var loginRequests = 0;
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/filter')) {
        return http.Response('{"filter_id":"synthetic-filter"}', 200);
      }
      if (request.url.path.endsWith('/login')) {
        loginRequests++;
        if (loginRequests == 1) {
          firstRequested.complete();
          return firstResponse.future;
        }
        return http.Response(
            '{"user_id":"@retained:synthetic.test",'
            '"device_id":"synthetic-device","access_token":"synthetic-second"}',
            200);
      }
      return syncResponse.future;
    });
    final client = _SyncClient(transport);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        suspendClient: (_) async {},
        readContinuityMetadata: (client) async => _metadata(client));
    Future<void> login() => matrix.loginWithTokenForExpectedIdentity(
        expectedMatrixUserId: client.userID,
        loginToken: 'synthetic-grant',
        homeserver: Uri.parse('https://synthetic.test'));
    Future<void>? second;
    final first = login();
    try {
      await firstRequested.future.timeout(const Duration(seconds: 3));
      second = login();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(loginRequests, 1,
          reason: 'a second login cannot overtake credential adoption');
      firstResponse.complete(http.Response(
          '{"user_id":"@retained:synthetic.test",'
          '"device_id":"synthetic-device","access_token":"synthetic-first"}',
          200));
      await Future.wait([first, second]);
      expect(loginRequests, 2);
      expect(client.accessToken, 'synthetic-second');
    } finally {
      if (!firstResponse.isCompleted) {
        firstResponse.complete(http.Response(
            '{"user_id":"@retained:synthetic.test",'
            '"device_id":"synthetic-device","access_token":"synthetic-first"}',
            200));
      }
      await first;
      await second;
      await client.abortSync();
      syncResponse.complete(http.Response('{"next_batch":"released"}', 200));
      await matrix.suspend();
      await client.dispose();
      transport.close();
    }
  });

  test('failed selected-owner binding retires it and closes replacement',
      () async {
    final secure = SecureSessionStore(MemorySecureKeyValueStore());
    final a = _ReadyClient('a');
    final b = _BindingFailureClient('b');
    final closed = <Client>[];
    final matrix = MatrixSdkE2eeClient(a,
        homeserver: Uri.parse('https://synthetic.test'),
        secureSessionStore: secure,
        suspendClient: (client) async {
          closed.add(client);
        },
        selectClientAccount: (_, __) async {},
        resumeClient: () async => b,
        readContinuityMetadata: (client) async => _metadata(client));
    final old = secure.startupProjectionCoordinator!;
    await expectLater(
        matrix.selectAccount(b.userID!, Uri.parse('https://synthetic.test')),
        throwsStateError);
    expect(secure.startupProjectionCoordinator, isNull);
    expect(old.beginDisplayCapture(), isNull);
    expect(closed, [a, b]);
    await matrix.suspend();
  });

  test('fresh SDK success replaces a cached old-session unavailable state',
      () async {
    var freshRequests = 0;
    String? freshTimeout;
    final nextResponse = Completer<http.Response>();
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/filter')) {
        return http.Response('{"filter_id":"filter"}', 200);
      }
      if (request.url.path.endsWith('/login')) {
        return http.Response(
            '{"user_id":"@retained:synthetic.test","device_id":"synthetic-device","access_token":"synthetic-new-token"}',
            200);
      }
      if (!request.url.path.endsWith('/sync')) {
        return http.Response('{}', 404);
      }
      if (request.headers.values
          .any((value) => value.contains('synthetic-old-token'))) {
        return http.Response(
            '{"errcode":"M_UNKNOWN_TOKEN","error":"synthetic old"}', 401);
      }
      freshRequests++;
      if (freshRequests == 1) {
        freshTimeout = request.url.queryParameters['timeout'];
        return http.Response('{"next_batch":"fresh-sdk-success"}', 200);
      }
      return nextResponse.future;
    });
    final client = _SyncClient(transport);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        suspendClient: (_) async {},
        readContinuityMetadata: (client) async => _metadata(client));
    final watchdog =
        MatrixSyncWatchdog(target: ClientSyncWatchdogTarget(client))..start();
    try {
      await client.oneShotSync();
      expect(watchdog.connectionStatus.value,
          MatrixConnectionStatus.serviceUnavailable);
      await matrix.loginWithTokenForExpectedIdentity(
          expectedMatrixUserId: client.userID,
          loginToken: 'synthetic-grant',
          homeserver: Uri.parse('https://synthetic.test'));
      for (var i = 0; i < 100 && client.prevBatch != 'fresh-sdk-success'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(client.prevBatch, 'fresh-sdk-success');
      expect(freshTimeout, '0');
      expect(watchdog.connectionStatus.value, MatrixConnectionStatus.connected);
      expect(matrix.credentialsInvalid, isFalse);
    } finally {
      await client.abortSync();
      nextResponse.complete(http.Response('{"next_batch":"released"}', 200));
      watchdog.dispose();
      await matrix.suspend();
      await client.dispose();
      transport.close();
    }
  });

  test('revocation while login acquisition waits prevents new-device login',
      () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final client = LogoutTrackingClient('anonymous');
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://synthetic.test'),
        suspendClient: (_) async {}, readContinuityMetadata: (active) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return _metadata(active);
    });
    final acquiring =
        expectLater(matrix.currentSessionCredentials(), throwsStateError);
    await entered.future.timeout(const Duration(seconds: 3));
    final login = expectLater(
        matrix.loginWithToken(
            loginToken: 'stale-grant',
            homeserver: Uri.parse('https://synthetic.test')),
        throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final suspended = matrix.suspend();
    release.complete();
    await Future.wait([acquiring, login, suspended]);
    expect(client.loggedIn, isFalse,
        reason: 'a request already dequeued must not revive after revocation');
    expect(client.matrixUserId, isNull);
    expect(client.immediateSyncStarts, 0);
  });

  for (final lateStatus in [401, 200]) {
    test('old token sync $lateStatus cannot mutate a successful retained login',
        () async {
      final oldRequested = Completer<void>();
      final oldResponse = Completer<http.Response>();
      final freshResponse = Completer<http.Response>();
      final freshRequested = Completer<void>();
      String? freshTimeout;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/filter')) {
          return http.Response('{"filter_id":"synthetic-filter"}', 200);
        }
        if (request.url.path.endsWith('/login')) {
          return http.Response(
              jsonEncode({
                'user_id': '@retained:synthetic.test',
                'device_id': 'synthetic-device',
                'access_token': 'synthetic-new-token'
              }),
              200);
        }
        if (request.url.path.endsWith('/sync')) {
          if (request.headers['Authorization'] ==
              'Bearer synthetic-old-token') {
            if (!oldRequested.isCompleted) oldRequested.complete();
            return oldResponse.future;
          }
          freshTimeout = request.url.queryParameters['timeout'];
          if (!freshRequested.isCompleted) freshRequested.complete();
          return freshResponse.future;
        }
        return http.Response('{}', 404);
      });
      final client = _SyncClient(transport);
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://synthetic.test'),
          suspendClient: (_) async {},
          readContinuityMetadata: (client) async => _metadata(client));
      final watchdog =
          MatrixSyncWatchdog(target: ClientSyncWatchdogTarget(client))..start();
      Future<void>? oldSync;
      try {
        oldSync = client.oneShotSync();
        await oldRequested.future.timeout(const Duration(seconds: 3));
        await matrix.loginWithTokenForExpectedIdentity(
            expectedMatrixUserId: client.userID,
            loginToken: 'synthetic-grant',
            homeserver: Uri.parse('https://synthetic.test'),
            deviceId: client.deviceID);
        expect(client.accessToken, 'synthetic-new-token');
        oldResponse.complete(http.Response(
            lateStatus == 401
                ? '{"errcode":"M_UNKNOWN_TOKEN","error":"synthetic old token"}'
                : '{"next_batch":"retired-response"}',
            lateStatus));
        await oldSync.timeout(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(client.accessToken, 'synthetic-new-token',
            reason: 'a stale sync must not clear the new successful login');
        expect(matrix.credentialsInvalid, isFalse);
        expect(client.prevBatch, isNot('retired-response'),
            reason:
                'old successful responses cannot publish new-session state');
        expect(watchdog.connectionStatus.value,
            isNot(MatrixConnectionStatus.serviceUnavailable),
            reason: 'a retired old-token response is not new-session downtime');
        await freshRequested.future.timeout(const Duration(seconds: 3));
        expect(freshTimeout, '0',
            reason: 'retained login restarts with an immediate SDK poll');
        freshResponse.complete(http.Response(
            '{"errcode":"M_UNKNOWN_TOKEN","error":"synthetic current token"}',
            401));
        for (var i = 0; i < 50 && client.accessToken != null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(client.accessToken, isNull,
            reason: 'a genuine current-token rejection must still fail closed');
        expect(matrix.credentialsInvalid, isTrue);
        expect(watchdog.connectionStatus.value,
            MatrixConnectionStatus.serviceUnavailable);
      } finally {
        if (!oldResponse.isCompleted) {
          oldResponse.complete(http.Response('{"next_batch":"old"}', 200));
        }
        await client.abortSync();
        if (!freshResponse.isCompleted) {
          freshResponse.complete(http.Response('{"next_batch":"new"}', 200));
        }
        await oldSync;
        watchdog.dispose();
        await matrix.suspend();
        await client.dispose();
        transport.close();
      }
    });
  }

  for (final failure in ['upload', 'rotation', 'persistence', 'logout']) {
    test('retained $failure failure cannot start fresh sync', () async {
      final persisting = Completer<void>();
      final release = Completer<void>();
      var syncRequests = 0;
      var reads = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(
              jsonEncode({
                'user_id': '@retained:synthetic.test',
                'device_id': failure == 'rotation'
                    ? 'rotated-device'
                    : 'synthetic-device',
                'access_token': 'synthetic-adopted'
              }),
              200);
        }
        syncRequests++;
        return http.Response('{"next_batch":"unexpected"}', 200);
      });
      final client = _SyncClient(transport);
      client.encryption.olmManager.succeed = failure != 'upload';
      final matrix = MatrixSdkE2eeClient(client,
          homeserver: Uri.parse('https://synthetic.test'),
          suspendClient: (_) async {},
          resumeClient: () async => client,
          rotateDeviceBinding: (_,
              {required expectedUserId,
              required previousDeviceId,
              required nextDeviceId}) async {
            throw StateError('synthetic rotation failure');
          },
          readContinuityMetadata: (active) async {
            reads++;
            if (reads == 2 &&
                (failure == 'persistence' || failure == 'logout')) {
              persisting.complete();
              await release.future;
              if (failure == 'persistence') {
                throw StateError('synthetic persistence failure');
              }
            }
            return _metadata(active);
          });
      Future<void>? suspended;
      Future<void>? queuedRejected;
      final login = matrix.loginWithTokenForExpectedIdentity(
          expectedMatrixUserId: client.userID,
          loginToken: 'synthetic-grant',
          homeserver: Uri.parse('https://synthetic.test'));
      final rejected = expectLater(login, throwsStateError);
      try {
        if (failure == 'persistence' || failure == 'logout') {
          await persisting.future.timeout(const Duration(seconds: 3));
          expect(matrix.credentialsInvalid, isTrue,
              reason: 'persisting credentials must not expose success early');
          if (failure == 'logout') {
            queuedRejected = expectLater(
                matrix.loginWithTokenForExpectedIdentity(
                    expectedMatrixUserId: client.userID,
                    loginToken: 'queued-before-logout',
                    homeserver: Uri.parse('https://synthetic.test')),
                throwsStateError);
            suspended = matrix.suspend();
          }
          release.complete();
        }
        await rejected;
        await suspended;
        await queuedRejected;
        expect(syncRequests, 0);
        expect(matrix.credentialsInvalid, isTrue);
        expect(client.syncPending, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await client.abortSync();
        await matrix.suspend();
        await client.dispose();
        transport.close();
      }
    });
  }

  test('repeated immediate starts preserve the current error backoff',
      () async {
    var syncRequests = 0;
    final firstError = Completer<void>();
    final transport = MockClient((request) async {
      if (request.url.path.endsWith('/filter')) {
        return http.Response('{"filter_id":"filter"}', 200);
      }
      syncRequests++;
      return http.Response(
          '{"errcode":"M_UNKNOWN","error":"synthetic unavailable"}', 503);
    });
    final client = _SyncClient(transport)..syncErrorTimeoutSec = 2;
    final subscription = client.onSyncStatus.stream.listen((s) {
      if (s.status == SyncStatus.error && !firstError.isCompleted) {
        firstError.complete();
      }
    });
    try {
      await client.abortSync();
      client.startSyncImmediately();
      await firstError.future.timeout(const Duration(seconds: 3));
      for (var i = 0; i < 5; i++) {
        client.startSyncImmediately();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(syncRequests, 1,
          reason: 'a current real error retains its ordinary retry budget');
    } finally {
      await client.abortSync();
      await subscription.cancel();
      await client.dispose();
      transport.close();
    }
  });
}
