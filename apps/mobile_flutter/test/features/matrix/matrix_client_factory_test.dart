import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:matrix/matrix.dart';

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

final class LogoutTrackingClient extends Client {
  LogoutTrackingClient(
    super.name, {
    this.loggedIn = false,
    this.matrixUserId,
    this.matrixDeviceId,
    this.syncError,
  });

  final bool loggedIn;
  final String? matrixUserId;
  final String? matrixDeviceId;
  final Object? syncError;
  var logoutCalls = 0;
  var syncCalls = 0;

  @override
  bool isLogged() => loggedIn;

  @override
  String? get userID => matrixUserId;

  @override
  String? get deviceID => matrixDeviceId;

  @override
  Future<void> logout() async => logoutCalls++;

  @override
  Future<SyncUpdate> sync({
    String? filter,
    String? since,
    bool? fullState,
    PresenceType? setPresence,
    int? timeout,
  }) async {
    syncCalls++;
    if (syncError != null) throw syncError!;
    return SyncUpdate(nextBatch: 'next');
  }
}

final class LifecycleBusiness implements DualDomainBusinessGateway {
  int logouts = 0;

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {}

  @override
  Future<MatrixLoginGrant> issueMatrixLoginToken() async =>
      const MatrixLoginGrant(
        loginToken: 'one-time-token',
        homeserver: 'https://matrix.test',
        expiresIn: 60,
        matrixUserId: '@alice:matrix.test',
      );

  @override
  Future<void> loginBusiness({
    required String username,
    required String password,
    required String deviceKey,
    required String deviceName,
  }) async {}

  @override
  Future<void> logoutBusiness() async => logouts++;
}

void main() {
  test('uses a stable encrypted database path and secure key', () async {
    final secureStore = SecureSessionStore(MemoryStore());
    String? openedName;
    String? openedPath;
    String? openedCipher;
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        openedName = clientName;
        openedPath = databasePath.replaceAll('\\', '/');
        openedCipher = cipher;
        return Client(clientName);
      },
    );

    final client = await factory.create();

    expect(client.clientName, 'liuhetong_mobile');
    expect(openedName, 'liuhetong_mobile');
    expect(openedPath, '/support/liuhetong_matrix.sqlite');
    expect(openedCipher, isNotEmpty);
    expect(await secureStore.matrixDatabaseKey(), openedCipher);
  });

  test('migrates an existing client to the configured public homeserver',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    Uri? migratedHomeserver;
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        return Client(clientName);
      },
      clientMigrator: (client, homeserver) async {
        migratedHomeserver = homeserver;
      },
    );

    await factory.create();

    expect(migratedHomeserver, Uri.parse('https://liuhetong888.com'));
  });

  test('explicit local clear deletes the database and rotates its cipher key',
      () async {
    final values = <String, String>{};
    final secureStore =
        SecureSessionStore(MemoryStore()..values.addAll(values));
    final oldClient = LogoutTrackingClient('old');
    final newClient = LogoutTrackingClient('new');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      databaseDeleter: (path) async =>
          events.add('delete:${path.replaceAll('\\', '/')}'),
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        events.add('open:$clientName');
        return newClient;
      },
    );
    final oldKey = await secureStore.matrixDatabaseKey();

    await factory.clearLocalChatData(oldClient);
    final newKey = await secureStore.matrixDatabaseKey();

    expect(events, [
      'dispose:old',
      'delete:/support/liuhetong_matrix.sqlite',
    ]);
    expect(oldClient.logoutCalls, 1);
    expect(newKey, isNot(oldKey));
  });

  test('suspend closes storage without reopening or exposing disposed client',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final oldClient = LogoutTrackingClient('old');
    final newClient = LogoutTrackingClient('new');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://liuhetong888.com'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      opener: (
          {required clientName, required databasePath, required cipher}) async {
        events.add('open:$clientName');
        return newClient;
      },
    );
    final oldKey = await secureStore.matrixDatabaseKey();

    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://liuhetong888.com'),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      clearClientData: factory.clearLocalChatData,
    );

    await matrix.suspend();

    expect(() => matrix.sdkClient, throwsStateError);
    expect(oldClient.logoutCalls, 0);
    expect(events, ['dispose:old']);
    expect(await secureStore.matrixDatabaseKey(), oldKey);
    expect(matrix.userId, oldClient.userID);
    expect(matrix.deviceId, oldClient.deviceID);
  });

  test('explicit local clear also works after the client is suspended',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final oldClient = LogoutTrackingClient('old');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      databaseDeleter: (path) async => events.add('delete'),
      opener: (
              {required clientName,
              required databasePath,
              required cipher}) async =>
          LogoutTrackingClient(clientName),
    );
    final oldKey = await secureStore.matrixDatabaseKey();
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      clearClientData: factory.clearLocalChatData,
    );

    await matrix.suspend();
    await matrix.clearLocalChatData();
    final newKey = await secureStore.matrixDatabaseKey();

    expect(events, ['dispose:old', 'delete']);
    expect(oldClient.logoutCalls, 0);
    expect(newKey, isNot(oldKey));
    expect(matrix.isLoggedIn, isFalse);
    expect(matrix.userId, isNull);
    expect(matrix.deviceId, isNull);
  });

  test('sync resumes lazily and retries after resume creation fails', () async {
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE',
    );
    final resumedClient = LogoutTrackingClient(
      'resumed',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE',
    );
    var resumeAttempts = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async {
        resumeAttempts++;
        if (resumeAttempts == 1) throw StateError('open failed');
        return resumedClient;
      },
    );

    await matrix.suspend();
    expect(resumeAttempts, 0);
    await expectLater(matrix.sync(), throwsStateError);
    expect(() => matrix.sdkClient, throwsStateError);

    await matrix.sync();

    expect(resumeAttempts, 2);
    expect(resumedClient.syncCalls, 1);
    expect(matrix.sdkClient, same(resumedClient));
  });

  test('resume rejects a different Matrix device identity', () async {
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final wrongClient = LogoutTrackingClient(
      'wrong',
      loggedIn: true,
      matrixUserId: '@mallory:matrix.test',
      matrixDeviceId: 'DEVICE-B',
    );
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async => wrongClient,
    );

    await matrix.suspend();

    await expectLater(matrix.sync(), throwsStateError);
    expect(() => matrix.sdkClient, throwsStateError);
    expect(wrongClient.syncCalls, 0);
  });

  test('concurrent sync operations share one resume attempt', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final resume = Completer<Client>();
    var resumeAttempts = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () {
        resumeAttempts++;
        return resume.future;
      },
    );
    await matrix.suspend();

    final first = matrix.sync();
    final second = matrix.sync();
    await Future<void>.delayed(Duration.zero);
    expect(resumeAttempts, 1);

    resume.complete(resumedClient);
    await Future.wait([first, second]);
    expect(resumedClient.syncCalls, 2);
  });

  test('suspend during resume rejects the late client handle', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final resume = Completer<Client>();
    final suspendedClients = <String>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (client) async => suspendedClients.add(client.clientName),
      resumeClient: () => resume.future,
    );
    await matrix.suspend();
    final sync = matrix.sync();
    await Future<void>.delayed(Duration.zero);

    await matrix.suspend();
    resume.complete(resumedClient);

    await expectLater(sync, throwsStateError);
    expect(() => matrix.sdkClient, throwsStateError);
    expect(resumedClient.syncCalls, 0);
    expect(suspendedClients, ['old', 'resumed']);
  });

  test('login sync failure suspends without deleting Matrix identity or key',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
      syncError: MatrixException.fromJson(
        {'errcode': 'M_UNKNOWN_TOKEN', 'error': 'expired'},
      ),
    );
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      disposer: (client) async => events.add('dispose:${client.clientName}'),
      databaseDeleter: (path) async => events.add('delete'),
      opener: (
              {required clientName,
              required databasePath,
              required cipher}) async =>
          oldClient,
    );
    final oldKey = await secureStore.matrixDatabaseKey();
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      clearClientData: factory.clearLocalChatData,
    );
    final business = LifecycleBusiness();
    final service = DualDomainLoginService(
      business: business,
      matrix: matrix,
      deviceKey: () => 'device-key',
    );

    await expectLater(
      service.login('alice', 'password'),
      throwsA(isA<MatrixException>()),
    );

    expect(events, ['dispose:old']);
    expect(oldClient.logoutCalls, 0);
    expect(matrix.userId, '@alice:matrix.test');
    expect(matrix.deviceId, 'DEVICE-A');
    expect(await secureStore.matrixDatabaseKey(), oldKey);
    expect(business.logouts, 1);
  });
}
