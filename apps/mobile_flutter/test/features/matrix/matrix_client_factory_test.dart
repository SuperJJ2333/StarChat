import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
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

  bool loggedIn;
  String? matrixUserId;
  String? matrixDeviceId;
  final Object? syncError;
  var logoutCalls = 0;
  var syncCalls = 0;
  Room? roomOverride;

  @override
  bool isLogged() => loggedIn;

  @override
  String? get userID => matrixUserId;

  @override
  String? get deviceID => matrixDeviceId;

  @override
  Room? getRoomById(String roomId) =>
      roomOverride?.id == roomId ? roomOverride : super.getRoomById(roomId);

  @override
  Future<
      (
        DiscoveryInformation?,
        GetVersionsResponse,
        List<LoginFlow>,
      )> checkHomeserver(
    Uri homeserverUrl, {
    bool checkWellKnown = true,
    Set<String>? overrideSupportedVersions,
  }) async =>
      (null, GetVersionsResponse(versions: const []), const <LoginFlow>[]);

  @override
  Future<LoginResponse> login(
    String type, {
    AuthenticationIdentifier? identifier,
    String? password,
    String? token,
    String? deviceId,
    String? initialDeviceDisplayName,
    bool? refreshToken,
    String? user,
    String? medium,
    String? address,
  }) async {
    loggedIn = true;
    matrixUserId ??= '@alice:matrix.test';
    matrixDeviceId ??= deviceId ?? 'DEVICE-A';
    return LoginResponse(
      accessToken: 'test-access-token',
      deviceId: matrixDeviceId!,
      userId: matrixUserId!,
    );
  }

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

Future<MatrixClientContinuityMetadata> testContinuityMetadata(
    Client client) async {
  final isLoggedIn = client.isLogged();
  return MatrixClientContinuityMetadata(
    isLoggedIn: isLoggedIn,
    userId: isLoggedIn ? client.userID : null,
    deviceId: isLoggedIn ? client.deviceID : null,
    ed25519Fingerprint: isLoggedIn ? 'fingerprint:${client.deviceID}' : null,
    databaseGeneration: 'generation-1',
  );
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

  test('factory continuity metadata persists fingerprint and DB generation',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final client = LogoutTrackingClient(
      'client',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-A',
      databaseGenerationFactory: () => 'generation-1',
    );

    final metadata = await factory.continuityMetadata(client);

    expect(metadata.ed25519Fingerprint, 'FINGERPRINT-A');
    expect(metadata.databaseGeneration, 'generation-1');
    expect(
      await secureStore.matrixBinding(),
      MatrixLocalBinding(
        version: 2,
        matrixUserId: '@alice:matrix.test',
        deviceId: 'DEVICE-A',
        homeserver: 'https://matrix.test',
        databaseGeneration: 'generation-1',
        ed25519Fingerprint: 'FINGERPRINT-A',
      ),
    );
  });

  test('new factory rejects a changed persisted Ed25519 fingerprint', () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final firstFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-A',
      databaseGenerationFactory: () => 'generation-1',
    );
    final firstClient = LogoutTrackingClient(
      'first-process',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    await firstFactory.continuityMetadata(firstClient);

    final restartedFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-B',
      databaseGenerationFactory: () => 'must-not-replace-persisted-generation',
    );
    final restartedClient = LogoutTrackingClient(
      'second-process',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );

    await expectLater(
      restartedFactory.continuityMetadata(restartedClient),
      throwsStateError,
    );
    expect(
      (await secureStore.matrixBinding())?.databaseGeneration,
      'generation-1',
    );
  });

  test('first wrapper operation validates the persisted restart fingerprint',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final baselineFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-A',
      databaseGenerationFactory: () => 'generation-1',
    );
    await baselineFactory.continuityMetadata(LogoutTrackingClient(
      'baseline',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    ));
    final restartedClient = LogoutTrackingClient(
      'restarted',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final restartedFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-B',
    );
    final matrix = MatrixSdkE2eeClient(
      restartedClient,
      homeserver: Uri.parse('https://matrix.test'),
      readContinuityMetadata: restartedFactory.continuityMetadata,
    );

    await expectLater(matrix.sync(), throwsStateError);
    expect(restartedClient.syncCalls, 0);
  });

  test('token login persists logged-in continuity before returning', () async {
    final client = LogoutTrackingClient('login-client');
    final observedLoggedStates = <bool>[];
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      readContinuityMetadata: (active) async {
        observedLoggedStates.add(active.isLogged());
        return testContinuityMetadata(active);
      },
    );

    await matrix.loginWithToken(
      loginToken: 'one-time-token',
      homeserver: Uri.parse('https://matrix.test'),
    );

    expect(observedLoggedStates, [false, true]);
  });

  test('version 1 binding is upgraded once with the current fingerprint',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    await secureStore.saveMatrixBinding(MatrixLocalBinding(
      version: 1,
      matrixUserId: '@alice:matrix.test',
      deviceId: 'DEVICE-A',
      homeserver: 'https://matrix.test',
      databaseGeneration: 'generation-1',
    ));
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-A',
    );

    await factory.continuityMetadata(LogoutTrackingClient(
      'legacy-process',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    ));

    expect((await secureStore.matrixBinding())?.version, 2);
    expect(
      (await secureStore.matrixBinding())?.ed25519Fingerprint,
      'FINGERPRINT-A',
    );
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
      readContinuityMetadata: factory.continuityMetadata,
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
      readContinuityMetadata: testContinuityMetadata,
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
      readContinuityMetadata: testContinuityMetadata,
    );

    await matrix.suspend();

    await expectLater(matrix.sync(), throwsStateError);
    expect(() => matrix.sdkClient, throwsStateError);
    expect(wrongClient.syncCalls, 0);
  });

  test('resume rejects the same device with a different Ed25519 fingerprint',
      () async {
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final resumedClient = LogoutTrackingClient(
      'resumed',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final closed = <Client>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (client) async => closed.add(client),
      resumeClient: () async => resumedClient,
      readContinuityMetadata: (client) async => MatrixClientContinuityMetadata(
        isLoggedIn: true,
        userId: '@alice:matrix.test',
        deviceId: 'DEVICE-A',
        ed25519Fingerprint:
            identical(client, oldClient) ? 'FINGERPRINT-A' : 'FINGERPRINT-B',
        databaseGeneration: 'generation-1',
      ),
    );

    await matrix.suspend();
    await expectLater(matrix.sync(), throwsStateError);

    expect(resumedClient.syncCalls, 0);
    expect(closed, [oldClient, resumedClient]);
    expect(() => matrix.sdkClient, throwsStateError);
  });

  test('resume rejects the same device from a different database generation',
      () async {
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final resumedClient = LogoutTrackingClient(
      'resumed',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
    );
    final closed = <Client>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (client) async => closed.add(client),
      resumeClient: () async => resumedClient,
      readContinuityMetadata: (client) async => MatrixClientContinuityMetadata(
        isLoggedIn: true,
        userId: '@alice:matrix.test',
        deviceId: 'DEVICE-A',
        ed25519Fingerprint: 'FINGERPRINT-A',
        databaseGeneration:
            identical(client, oldClient) ? 'generation-1' : 'generation-2',
      ),
    );

    await matrix.suspend();
    await expectLater(matrix.sync(), throwsStateError);

    expect(resumedClient.syncCalls, 0);
    expect(closed, [oldClient, resumedClient]);
    expect(() => matrix.sdkClient, throwsStateError);
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

  test('suspend during resume waits and then closes the resumed handle',
      () async {
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

    final suspend = matrix.suspend();
    resume.complete(resumedClient);

    await sync;
    await suspend;
    expect(() => matrix.sdkClient, throwsStateError);
    expect(resumedClient.syncCalls, 1);
    expect(suspendedClients, ['old', 'resumed']);
  });

  test('resume waits until an in-flight suspend finishes', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final suspendStarted = Completer<void>();
    final allowSuspend = Completer<void>();
    var resumeAttempts = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendStarted.complete();
        await allowSuspend.future;
      },
      resumeClient: () async {
        resumeAttempts++;
        return resumedClient;
      },
    );

    final suspend = matrix.suspend();
    await suspendStarted.future;
    final sync = matrix.sync();
    await Future<void>.delayed(Duration.zero);

    expect(matrix.sdkClient, same(oldClient));
    expect(resumeAttempts, 0);

    allowSuspend.complete();
    await suspend;
    await sync;
    expect(resumeAttempts, 1);
    expect(resumedClient.syncCalls, 1);
  });

  test('failed suspend keeps the active handle and can be retried', () async {
    final oldClient = LogoutTrackingClient('old');
    var suspendAttempts = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendAttempts++;
        if (suspendAttempts == 1) throw StateError('close failed');
      },
      resumeClient: () async => throw StateError('must not resume'),
    );

    await expectLater(matrix.suspend(), throwsStateError);
    expect(matrix.sdkClient, same(oldClient));

    await matrix.suspend();

    expect(suspendAttempts, 2);
    expect(() => matrix.sdkClient, throwsStateError);
  });

  test('clear waits for an in-flight resume and clears its only handle',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final resume = Completer<Client>();
    final clearedClients = <Client?>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () => resume.future,
      clearClientData: (client) async => clearedClients.add(client),
    );
    await matrix.suspend();
    final sync = matrix.sync();
    await Future<void>.delayed(Duration.zero);

    final clear = matrix.clearLocalChatData();
    await Future<void>.delayed(Duration.zero);
    expect(clearedClients, isEmpty);

    resume.complete(resumedClient);
    await sync;
    await clear;

    expect(clearedClients, hasLength(1));
    expect(clearedClients.single, same(resumedClient));
    expect(() => matrix.sdkClient, throwsStateError);
  });

  test('public client operation waits for an in-flight suspend', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final suspendStarted = Completer<void>();
    final allowSuspend = Completer<void>();
    final operatedClients = <Client>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendStarted.complete();
        await allowSuspend.future;
      },
      resumeClient: () async => resumedClient,
    );

    final suspend = matrix.suspend();
    await suspendStarted.future;
    final operation = matrix.runClientOperation<void>((client) async {
      operatedClients.add(client);
    });
    await Future<void>.delayed(Duration.zero);
    expect(operatedClients, isEmpty);

    allowSuspend.complete();
    await suspend;
    await operation;
    expect(operatedClients, [resumedClient]);
  });

  test('public client operation completes before explicit clear', () async {
    final oldClient = LogoutTrackingClient('old');
    final operationStarted = Completer<void>();
    final allowOperation = Completer<void>();
    final clearedClients = <Client?>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      clearClientData: (client) async => clearedClients.add(client),
    );

    final operation = matrix.runClientOperation<void>((_) async {
      operationStarted.complete();
      await allowOperation.future;
    });
    await operationStarted.future;
    final clear = matrix.clearLocalChatData();
    await Future<void>.delayed(Duration.zero);
    expect(clearedClients, isEmpty);

    allowOperation.complete();
    await operation;
    await clear;
    expect(clearedClients, [oldClient]);
  });

  test('public client operation cannot return a raw Client or Room', () async {
    final client = LogoutTrackingClient('old');
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
    );

    await expectLater(
      matrix.runClientOperation<Client>((active) async => active),
      throwsStateError,
    );
  });

  test('managed client stream detaches on suspend and rebuilds on resume',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final oldEvents = StreamController<String>.broadcast();
    final resumedEvents = StreamController<String>.broadcast();
    final received = <String>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async => resumedClient,
    );
    final subscription = await matrix.subscribeClientStream<String>(
      streamFor: (client) => identical(client, oldClient)
          ? oldEvents.stream
          : resumedEvents.stream,
      onData: received.add,
    );

    oldEvents.add('before-suspend');
    await Future<void>.delayed(Duration.zero);
    await matrix.suspend();
    oldEvents.add('after-suspend');
    await Future<void>.delayed(Duration.zero);
    await matrix.sync();
    resumedEvents.add('after-resume');
    await Future<void>.delayed(Duration.zero);

    expect(received, ['before-suspend', 'after-resume']);
    await subscription.cancel();
    await oldEvents.close();
    await resumedEvents.close();
  });

  test('managed client resource closes before suspend and rebuilds on resume',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final events = <String>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (client) async =>
          events.add('suspend:${client.clientName}'),
      resumeClient: () async => resumedClient,
      clearClientData: (client) async =>
          events.add('clear:${client?.clientName}'),
    );
    await matrix.registerManagedResource(
      open: (client) async => events.add('open:${client.clientName}'),
      close: () async => events.add('close'),
    );

    await matrix.suspend();
    await matrix.sync();
    await matrix.clearLocalChatData();

    expect(events, [
      'open:old',
      'close',
      'suspend:old',
      'open:resumed',
      'close',
      'clear:resumed',
    ]);
  });

  test('room lease is revoked before suspend without holding the queue',
      () async {
    final client = LogoutTrackingClient('old');
    client.roomOverride = Room(id: '!room:matrix.test', client: client);
    final events = <String>[];
    final drainStarted = Completer<void>();
    final allowDrain = Completer<void>();
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async => events.add('suspend'),
    );
    final lease = await matrix.openRoomLease('!room:matrix.test');
    lease.setOnRevoked(() async {
      events.add('revoke');
      drainStarted.complete();
      await allowDrain.future;
    });

    final suspend = matrix.suspend();
    await drainStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(events, ['revoke']);

    allowDrain.complete();
    await suspend;

    expect(events, ['revoke', 'suspend']);
    expect(() => lease.room, throwsStateError);
  });

  test('failed clear blocks resume and retries the same client handle',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final clearedClients = <Client?>[];
    var clearAttempts = 0;
    var resumeAttempts = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async {
        resumeAttempts++;
        return LogoutTrackingClient('unexpected');
      },
      clearClientData: (client) async {
        clearedClients.add(client);
        clearAttempts++;
        if (clearAttempts == 1) throw StateError('delete failed');
      },
    );

    await expectLater(matrix.clearLocalChatData(), throwsStateError);
    await expectLater(matrix.sync(), throwsStateError);
    expect(resumeAttempts, 0);

    await matrix.clearLocalChatData();

    expect(clearedClients, [oldClient, oldClient]);
    expect(() => matrix.sdkClient, throwsStateError);
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
      fingerprintReader: (_) => 'FINGERPRINT-A',
      databaseGenerationFactory: () => 'generation-1',
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
      readContinuityMetadata: factory.continuityMetadata,
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
