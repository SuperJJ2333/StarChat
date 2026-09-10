import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/encryption/ssss.dart';
import 'dart:typed_data';
import 'package:liuhetong_mobile/core/business_auth_contracts.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/auth/login_controller.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_security_logger.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SnapshotClient extends LogoutTrackingClient {
  SnapshotClient() : super('snapshot', matrixUserId: '@me:test');
  final snapshotRooms = <Room>[];
  int joinCalls = 0;
  @override
  Future<String> joinRoom(String id,
      {List<String>? serverName,
      List<String>? via,
      String? reason,
      ThirdPartySigned? thirdPartySigned}) async {
    joinCalls++;
    return id;
  }

  @override
  Future<void> oneShotSync() async {}

  @override
  List<Room> get rooms => snapshotRooms;
  final deletedPushers = <String>[];
  @override
  Future<void> postPusher(Pusher pusher, {bool? append}) async {}
  @override
  Future<void> deletePusher(PusherId id) async {
    deletedPushers.add(id.pushkey);
  }
}

class FailedInitClient extends Client {
  FailedInitClient()
      : super('failed-init',
            preserveStoreOnInvalidToken: true,
            databaseBuilder: (_) async =>
                throw StateError('synthetic open failure'));
  bool disposed = false;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {
    disposed = true;
    await super.dispose(closeDatabase: closeDatabase);
  }
}

class FailedOpenDatabase extends Fake implements MatrixSdkDatabase {
  @override
  Future<void> open() async => throw StateError('synthetic schema failure');
}

class SnapshotRoom extends Room {
  SnapshotRoom(
      {required super.id, required super.client, required this.joined});
  final bool joined;
  int refreshCalls = 0;
  final refresh = Completer<List<User>>();
  Event? snapshotEvent;
  @override
  User unsafeGetUserFromMemoryOrFallback(String id) =>
      User(id, room: this, displayName: 'Fixture member');
  @override
  Membership get membership => joined ? Membership.join : Membership.invite;
  @override
  String get name => 'Cached group name';
  @override
  Event? get lastEvent => snapshotEvent;
  @override
  Future<List<User>> requestParticipants(
      [List<Membership> memberships = const [
        Membership.join,
        Membership.invite,
        Membership.knock
      ],
      bool suppressWarning = false,
      bool cache = true]) {
    refreshCalls++;
    return refresh.future;
  }
}

class DeferredBackupStore extends Fake implements SSSS {
  final started = Completer<void>();
  final result = Completer<OpenSSSS>();
  @override
  Future<OpenSSSS> createKey([String? passphrase]) {
    started.complete();
    return result.future;
  }
}

class DeferredEncryption extends Fake implements Encryption {
  DeferredEncryption(this.ssss);
  @override
  final SSSS ssss;
}

class BackupHandle extends Fake implements OpenSSSS {
  int cacheCalls = 0;
  @override
  String? get recoveryKey => 'test-only-secret';
  @override
  Future<void> maybeCacheAll() async {
    cacheCalls++;
  }
}

class BackupRaceClient extends LogoutTrackingClient {
  BackupRaceClient(this.encryption) : super('backup-race');
  @override
  final Encryption? encryption;
}

final class _TestSasRequest implements MatrixSasRequestHandle {
  const _TestSasRequest(this.id, {this.onAccept});
  final String id;
  final Future<void> Function()? onAccept;
  @override
  Future<void> accept() => onAccept?.call() ?? Future<void>.value();
  @override
  Future<void> confirmSas() async {}
  @override
  Future<void> continueSas() async {}
  @override
  Future<void> reject() async {}
  @override
  void dispose() {}
}

Future<
    ({
      MatrixSasRequestHandle handle,
      StreamController<MatrixSasRequestHandle> source,
    })> _issueTrackedSas(
  MatrixSdkE2eeClient matrix,
  _TestSasRequest request,
) async {
  final source = StreamController<MatrixSasRequestHandle>.broadcast();
  late MatrixSasRequestHandle handle;
  await matrix.subscribeSasRequests(
    testSource: () => source.stream,
    onData: (request) => handle = request,
  );
  source.add(request);
  await Future<void>.delayed(Duration.zero);
  return (handle: handle, source: source);
}

final class MemoryStore implements SecureKeyValueStore {
  final values = <String, String>{};
  String? failDeleteOnceFor;
  @override
  Future<void> delete(String key) async {
    if (failDeleteOnceFor == key) {
      failDeleteOnceFor = null;
      throw StateError('simulated secure storage interruption');
    }
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

class LogoutTrackingClient extends Client {
  LogoutTrackingClient(
    super.name, {
    this.loggedIn = false,
    this.matrixUserId,
    this.matrixDeviceId,
    this.syncError,
    super.httpClient,
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

final class _NeverLogoutClient extends LogoutTrackingClient {
  _NeverLogoutClient(super.name);

  final neverCompletes = Completer<void>();

  @override
  Future<void> logout() => neverCompletes.future;
}

final class EncryptedMediaTrackingClient extends LogoutTrackingClient {
  EncryptedMediaTrackingClient(super.name);
  @override
  bool get fileEncryptionEnabled => true;
}

final class MediaTrackingRoom extends Room {
  MediaTrackingRoom({required super.id, required super.client});

  @override
  bool get encrypted => true;

  MatrixFile? sentFile;
  MatrixImageFile? sentThumbnail;

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
  }) async {
    sentFile = file;
    sentThumbnail = thumbnail;
    return r'$event';
  }
}

final class LifecycleBusiness implements DualDomainBusinessGateway {
  int logouts = 0;

  @override
  Future<void> bindMatrixUserId(String matrixUserId) async {}

  @override
  Future<String?> currentMatrixUserId() async => '@alice:matrix.test';

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

class MatrixTestPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '${Directory.current.parent.parent.path}/docs/verification/artifacts/2026-09-10/conversation-state-main/matrix-cache-tests';
}

void main() {
  setUp(() => PathProviderPlatform.instance = MatrixTestPaths());
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('normal sync cannot adopt a fresh client after explicit clear',
      () async {
    final fresh = LogoutTrackingClient('fresh');
    final matrix = MatrixSdkE2eeClient(LogoutTrackingClient('old'),
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {},
        resumeClient: () async => fresh,
        clearClientData: (_) async {},
        readContinuityMetadata: testContinuityMetadata);
    await matrix.clearLocalChatData();
    await expectLater(matrix.sync(), throwsStateError);
    expect(fresh.syncCalls, 0);
    expect(matrix.debugHasActiveClient, isFalse);
    await matrix.loginWithToken(
        loginToken: 'test-once', homeserver: Uri.parse('https://matrix.test'));
    expect(matrix.isLoggedIn, isTrue);
  });
  test('clear cannot authorize adoption of an already logged-in client',
      () async {
    final stale = LogoutTrackingClient('stale',
        loggedIn: true,
        matrixUserId: '@old:matrix.test',
        matrixDeviceId: 'OLD');
    final matrix = MatrixSdkE2eeClient(LogoutTrackingClient('old'),
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {},
        resumeClient: () async => stale,
        clearClientData: (_) async {},
        readContinuityMetadata: testContinuityMetadata);
    await matrix.clearLocalChatData();
    await expectLater(
        matrix.loginWithToken(
            loginToken: 'test-once',
            homeserver: Uri.parse('https://matrix.test')),
        throwsStateError);
    expect(matrix.debugHasActiveClient, isFalse);
  });
  test('failed fresh opener can retry only through explicit login', () async {
    var opens = 0;
    final matrix = MatrixSdkE2eeClient(LogoutTrackingClient('old'),
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {}, resumeClient: () async {
      if (++opens == 1) throw StateError('open failed');
      return LogoutTrackingClient('fresh');
    },
        clearClientData: (_) async {},
        readContinuityMetadata: testContinuityMetadata);
    await matrix.clearLocalChatData();
    await expectLater(
        matrix.loginWithToken(
            loginToken: 'test-once',
            homeserver: Uri.parse('https://matrix.test')),
        throwsStateError);
    await matrix.loginWithToken(
        loginToken: 'test-new', homeserver: Uri.parse('https://matrix.test'));
    expect(matrix.isLoggedIn, isTrue);
    expect(opens, 2);
  });

  test('token login after confirmed local clear opens fresh client', () async {
    final old = LogoutTrackingClient('old',
        loggedIn: true,
        matrixUserId: '@old:matrix.test',
        matrixDeviceId: 'OLD');
    final fresh = LogoutTrackingClient('fresh');
    final matrix = MatrixSdkE2eeClient(old,
        homeserver: Uri.parse('https://matrix.test'),
        suspendClient: (_) async {},
        resumeClient: () async => fresh,
        clearClientData: (_) async {},
        readContinuityMetadata: testContinuityMetadata);
    await matrix.clearLocalChatData();
    await matrix.loginWithToken(
        loginToken: 'test-once', homeserver: Uri.parse('https://matrix.test'));
    expect(matrix.isLoggedIn, isTrue);
    expect(matrix.userId, '@alice:matrix.test');
    expect(matrix.debugActiveClientName, 'fresh');
  });

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

  test('soft logged out continuity retains identity and validates binding',
      () async {
    final store = SecureSessionStore(MemoryStore());
    final client = LogoutTrackingClient('retained',
        loggedIn: true,
        matrixUserId: '@alice:matrix.test',
        matrixDeviceId: 'DEVICE-A');
    final factory = MatrixClientFactory(
        sessionStore: store,
        homeserver: Uri.parse('https://matrix.test'),
        fingerprintReader: (_) => 'FINGERPRINT-A');
    await factory.continuityMetadata(client);
    client.loggedIn = false;
    final retained = await factory.continuityMetadata(client);
    expect(retained.isLoggedIn, isFalse);
    expect(retained.userId, '@alice:matrix.test');
    expect(retained.deviceId, 'DEVICE-A');
    expect(retained.ed25519Fingerprint, 'FINGERPRINT-A');
    client.matrixDeviceId = 'UNEXPECTED';
    await expectLater(factory.continuityMetadata(client), throwsStateError);
  });

  test('stale binding on an empty store is reset so reinstall can log in',
      () async {
    // iOS reinstall: the Keychain keeps the continuity binding while the
    // encrypted database is destroyed with the sandbox. The reopened store
    // holds no session, so the surviving binding describes nothing; it must
    // be reset instead of rejecting every future login (the L07 wedge).
    final store = SecureSessionStore(MemoryStore());
    await store.saveMatrixBinding(MatrixLocalBinding(
      version: 2,
      matrixUserId: '@alice:matrix.test',
      deviceId: 'DEVICE-A',
      homeserver: 'https://matrix.test',
      databaseGeneration: 'destroyed-generation',
      ed25519Fingerprint: 'FINGERPRINT-A',
    ));
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      fingerprintReader: (_) => null,
      databaseGenerationFactory: () => 'fresh-generation',
    );

    final metadata = await factory.continuityMetadata(LogoutTrackingClient(
      'reinstalled',
      loggedIn: false,
    ));

    expect(metadata.isLoggedIn, isFalse);
    expect(metadata.userId, isNull);
    expect(metadata.deviceId, isNull);
    expect(metadata.databaseGeneration, 'fresh-generation',
        reason: 'the fresh store must not reuse the destroyed generation');
    expect(await store.matrixBinding(), isNull,
        reason: 'the stale binding is consumed by the reset');
  });

  test('failed migration closes client without deleting store', () async {
    final client = Client('failed-migration');
    final disposed = <Client>[];
    var deletes = 0;
    final factory = MatrixClientFactory(
        sessionStore: SecureSessionStore(MemoryStore()),
        homeserver: Uri.parse('https://matrix.test'),
        supportDirectoryPath: () async => '/support',
        opener: (
                {required clientName,
                required databasePath,
                required cipher}) async =>
            client,
        clientMigrator: (_, __) async => throw StateError('migration failed'),
        disposer: (value) async {
          disposed.add(value);
          await value.dispose();
        },
        databaseDeleter: (_) async {
          deletes++;
        });
    await expectLater(factory.create(), throwsStateError);
    expect(disposed, [client]);
    expect(deletes, 0);
  });

  test('failed SDK init closes retained client handle', () async {
    final client = FailedInitClient();
    final errors = client.onLoginStateChanged.stream
        .listen((_) {}, onError: (Object _) {});
    try {
      await expectLater(
          MatrixClientFactory.initializeClient(client), throwsException);
      expect(client.disposed, isTrue);
    } finally {
      await errors.cancel();
      if (!client.disposed) await client.dispose();
    }
  });

  test('failed SDK database open closes raw SQLite handle', () async {
    var closes = 0;
    await expectLater(
        MatrixClientFactory.initializeDatabase(FailedOpenDatabase(), () async {
          closes++;
        }),
        throwsStateError);
    expect(closes, 1);
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
    expect(oldClient.logoutCalls, 0);
    expect(newKey, isNot(oldKey));
  });

  test('explicit clear never waits for a homeserver logout', () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final client = _NeverLogoutClient('old');
    final events = <String>[];
    final factory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      disposer: (_) async => events.add('dispose'),
      databaseDeleter: (_) async => events.add('delete'),
    );

    await factory.clearLocalChatData(client).timeout(
          const Duration(milliseconds: 100),
        );

    expect(events, ['dispose', 'delete']);
    expect(client.logoutCalls, 0);
    expect(await secureStore.matrixClearPending(), isFalse);
  });

  test('factory restart completes a tombstoned clear before reopening storage',
      () async {
    final memory = MemoryStore();
    final secureStore = SecureSessionStore(memory);
    final oldKey = await secureStore.matrixDatabaseKey();
    var deleteAttempts = 0;
    final openedCiphers = <String>[];
    MatrixClientFactory buildFactory() => MatrixClientFactory(
          sessionStore: secureStore,
          homeserver: Uri.parse('https://matrix.test'),
          supportDirectoryPath: () async => '/support',
          disposer: (_) async {},
          databaseDeleter: (_) async {
            deleteAttempts++;
            if (deleteAttempts == 1) {
              throw StateError('simulated process interruption');
            }
          },
          opener: ({
            required clientName,
            required databasePath,
            required cipher,
          }) async {
            openedCiphers.add(cipher);
            return LogoutTrackingClient(clientName);
          },
        );

    await expectLater(
      buildFactory().clearLocalChatData(LogoutTrackingClient('old')),
      throwsStateError,
    );

    expect(await secureStore.matrixClearPending(), isTrue);
    expect(memory.values.values, contains('{"version":1,"pending":true}'));
    final reopened = await buildFactory().create();

    expect(reopened.clientName, MatrixClientFactory.clientName);
    expect(deleteAttempts, 2);
    expect(await secureStore.matrixClearPending(), isFalse);
    expect(openedCiphers.single, isNot(oldKey));
  });

  test('tombstone survives close failure and restart completes the clear',
      () async {
    final memory = MemoryStore();
    final secureStore = SecureSessionStore(memory);
    var deleteCalls = 0;
    final failingFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      disposer: (_) async => throw StateError('close interrupted'),
      databaseDeleter: (_) async => deleteCalls++,
    );

    await expectLater(
      failingFactory.clearLocalChatData(LogoutTrackingClient('old')),
      throwsStateError,
    );
    expect(await secureStore.matrixClearPending(), isTrue);
    expect(deleteCalls, 0);

    final recoveryFactory = MatrixClientFactory(
      sessionStore: secureStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      databaseDeleter: (_) async => deleteCalls++,
      opener: ({
        required clientName,
        required databasePath,
        required cipher,
      }) async =>
          LogoutTrackingClient(clientName),
    );
    await recoveryFactory.create();

    expect(deleteCalls, 1);
    expect(await secureStore.matrixClearPending(), isFalse);
  });

  test(
      'tombstone survives identity-key deletion failure and retries all phases',
      () async {
    final memory = MemoryStore();
    final secureStore = SecureSessionStore(memory);
    await secureStore.matrixDatabaseKey();
    memory.failDeleteOnceFor = memory.values.keys.singleWhere(
      (key) => key.contains('matrix_database_key'),
    );
    var deleteCalls = 0;
    MatrixClientFactory buildFactory() => MatrixClientFactory(
          sessionStore: secureStore,
          homeserver: Uri.parse('https://matrix.test'),
          supportDirectoryPath: () async => '/support',
          disposer: (_) async {},
          databaseDeleter: (_) async => deleteCalls++,
          opener: ({
            required clientName,
            required databasePath,
            required cipher,
          }) async =>
              LogoutTrackingClient(clientName),
        );

    await expectLater(
      buildFactory().clearLocalChatData(LogoutTrackingClient('old')),
      throwsStateError,
    );
    expect(await secureStore.matrixClearPending(), isTrue);
    expect(deleteCalls, 1);

    await buildFactory().create();

    expect(deleteCalls, 2);
    expect(await secureStore.matrixClearPending(), isFalse);
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

    expect(matrix.debugHasActiveClient, isFalse);
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
    expect(matrix.debugHasActiveClient, isFalse);

    await matrix.sync();

    expect(resumeAttempts, 2);
    expect(resumedClient.syncCalls, 1);
    expect(matrix.debugActiveClientName, resumedClient.clientName);
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
    expect(matrix.debugHasActiveClient, isFalse);
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
    expect(matrix.debugHasActiveClient, isFalse);
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
    expect(matrix.debugHasActiveClient, isFalse);
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
    expect(matrix.debugHasActiveClient, isFalse);
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

    expect(matrix.debugActiveClientName, oldClient.clientName);
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
    expect(matrix.debugActiveClientName, oldClient.clientName);

    await matrix.suspend();

    expect(suspendAttempts, 2);
    expect(matrix.debugHasActiveClient, isFalse);
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
    expect(matrix.debugHasActiveClient, isFalse);
  });

  test('tracked capability action fails closed during an in-flight suspend',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final suspendStarted = Completer<void>();
    final allowSuspend = Completer<void>();
    var operated = false;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {
        suspendStarted.complete();
        await allowSuspend.future;
      },
    );

    final issued = await _issueTrackedSas(
      matrix,
      _TestSasRequest('request', onAccept: () async => operated = true),
    );
    final suspend = matrix.suspend();
    await suspendStarted.future;
    final operation = issued.handle.accept();
    await expectLater(operation, throwsStateError);
    expect(operated, isFalse);

    allowSuspend.complete();
    await suspend;
    expect(operated, isFalse);
    await issued.source.close();
  });

  test('tracked capability action completes before explicit clear', () async {
    final oldClient = LogoutTrackingClient('old');
    final operationStarted = Completer<void>();
    final allowOperation = Completer<void>();
    final clearedClients = <Client?>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      clearClientData: (client) async => clearedClients.add(client),
    );

    final issued = await _issueTrackedSas(
      matrix,
      _TestSasRequest('request', onAccept: () async {
        operationStarted.complete();
        await allowOperation.future;
      }),
    );
    final operation = issued.handle.accept();
    await operationStarted.future;
    final clear = matrix.clearLocalChatData();
    await Future<void>.delayed(Duration.zero);
    expect(clearedClients, isEmpty);

    allowOperation.complete();
    await operation;
    await clear;
    expect(clearedClients, [oldClient]);
    await issued.source.close();
  });

  test('suspend fails closed within a bound without closing an in-use database',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final operationStarted = Completer<void>();
    final allowOperation = Completer<void>();
    final suspendedClients = <Client>[];
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      lifecycleDrainTimeout: const Duration(milliseconds: 10),
      suspendClient: (client) async => suspendedClients.add(client),
    );
    final issued = await _issueTrackedSas(
      matrix,
      _TestSasRequest('request', onAccept: () async {
        operationStarted.complete();
        await allowOperation.future;
      }),
    );
    final operation = issued.handle.accept();
    await operationStarted.future;

    await expectLater(
      matrix.suspend(),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_LIFECYCLE_DRAIN_TIMEOUT',
      )),
    );

    expect(suspendedClients, isEmpty);
    expect(matrix.debugHasActiveClient, isTrue);
    allowOperation.complete();
    await operation;
    await matrix.suspend();
    expect(suspendedClients, [oldClient]);
    await issued.source.close();
  });

  for (final errcode in ['M_UNKNOWN_TOKEN', 'M_FORBIDDEN']) {
    test('$errcode records explicit invalid credential state', () async {
      final matrix = MatrixSdkE2eeClient(
        LogoutTrackingClient(
          'old',
          loggedIn: true,
          matrixUserId: '@alice:matrix.test',
          matrixDeviceId: 'DEVICE-A',
          syncError: MatrixException.fromJson({
            'errcode': errcode,
            'error': 'expired',
          }),
        ),
        homeserver: Uri.parse('https://matrix.test'),
        readContinuityMetadata: (_) async =>
            const MatrixClientContinuityMetadata(
          isLoggedIn: true,
          userId: '@alice:matrix.test',
          deviceId: 'DEVICE-A',
          ed25519Fingerprint: 'FINGERPRINT-A',
          databaseGeneration: 'generation-a',
        ),
      );

      expect(matrix.credentialsInvalid, isFalse);
      await expectLater(matrix.sync(), throwsA(isA<MatrixException>()));
      expect(matrix.credentialsInvalid, isTrue);
      expect(matrix.deviceId, 'DEVICE-A');
    });
  }

  test(
      'token response tuple preserves continuity before a phased tombstone clear',
      () async {
    Map<String, dynamic>? loginBody;
    final httpClient = MockClient((request) async {
      if (request.url.path.endsWith('/login')) {
        loginBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'access_token': 'replacement-token',
            'refresh_token': 'replacement-refresh-token',
            'expires_in_ms': 60000,
            'device_id': 'DEVICE-A',
            'user_id': '@alice:matrix.test',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final client = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
      syncError: MatrixException.fromJson(const {
        'errcode': 'M_UNKNOWN_TOKEN',
        'error': 'expired',
      }),
      httpClient: httpClient,
    );
    final sessionStore = SecureSessionStore(MemoryStore());
    final oldCipher = await sessionStore.matrixDatabaseKey();
    final factory = MatrixClientFactory(
      sessionStore: sessionStore,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/support',
      fingerprintReader: (_) => 'FINGERPRINT-A',
      databaseGenerationFactory: () => 'generation-a',
    );
    final before = await factory.continuityMetadata(client);
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      readContinuityMetadata: factory.continuityMetadata,
    );
    await expectLater(matrix.sync(), throwsA(isA<MatrixException>()));

    await matrix.loginWithToken(
      loginToken: 'one-time-token',
      homeserver: Uri.parse('https://matrix.test'),
      deviceId: 'DEVICE-A',
    );
    final after = await factory.continuityMetadata(client);

    expect(loginBody?['device_id'], 'DEVICE-A');
    expect(matrix.credentialsInvalid, isFalse);
    expect(
      (
        after.userId,
        after.deviceId,
        after.ed25519Fingerprint,
        after.databaseGeneration,
      ),
      (
        before.userId,
        before.deviceId,
        before.ed25519Fingerprint,
        before.databaseGeneration,
      ),
    );
    expect(client.accessToken, 'replacement-token');
    expect(client.accessTokenExpiresAt, isNotNull);
    expect(client.logoutCalls, 0);

    var deleteAttempts = 0;
    MatrixClientFactory clearFactory({required bool interruptDelete}) =>
        MatrixClientFactory(
          sessionStore: sessionStore,
          homeserver: Uri.parse('https://matrix.test'),
          supportDirectoryPath: () async => '/support',
          disposer: (_) async {},
          databaseDeleter: (_) async {
            deleteAttempts++;
            if (interruptDelete) {
              throw StateError('simulated interruption after token refresh');
            }
          },
          opener: ({
            required clientName,
            required databasePath,
            required cipher,
          }) async {
            expect(cipher, isNot(oldCipher));
            return LogoutTrackingClient(clientName);
          },
        );
    await expectLater(
      clearFactory(interruptDelete: true).clearLocalChatData(client),
      throwsStateError,
    );
    expect(await sessionStore.matrixClearPending(), isTrue);

    await clearFactory(interruptDelete: false).create();

    expect(deleteAttempts, 2);
    expect(await sessionStore.matrixClearPending(), isFalse);
    expect(await sessionStore.matrixBinding(), isNull);
  });

  test(
      'conversation snapshot is local, joined only, and retains message metadata',
      () async {
    final client = SnapshotClient();
    final room = SnapshotRoom(id: '!joined:test', client: client, joined: true);
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Message,
        eventId: r'$video',
        senderId: '@me:test',
        originServerTs: DateTime.utc(2026),
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'video',
          'info': {'duration': 1234}
        });
    client.snapshotRooms.addAll([
      room,
      SnapshotRoom(id: '!invite:test', client: client, joined: false)
    ]);
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final snapshot = await matrix.conversations
        .snapshot()
        .timeout(const Duration(seconds: 1));
    expect(room.refreshCalls, 0);
    expect(snapshot.rooms.map((room) => room.id), ['!joined:test']);
    expect(snapshot.rooms.single.name, 'Cached group name');
    expect(snapshot.rooms.single.lastEvent!.messageType, MessageTypes.Video);
    expect(
        snapshot.rooms.single.lastEvent!.content['info'], {'duration': 1234});
    expect(() => snapshot.rooms.single.lastEvent!.content.clear(),
        throwsUnsupportedError);
    final first = matrix.conversations.refreshMembers();
    final second = matrix.conversations.refreshMembers();
    await Future<void>.delayed(Duration.zero);
    expect(room.refreshCalls, 1);
    room.refresh.complete([]);
    await Future.wait([first, second]);
  });

  test(
      'home pusher cleanup after revoke removes only created identity without queue deadlock',
      () async {
    final client = SnapshotClient();
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), suspendClient: (_) async {});
    late MatrixAppHomeCapability capability;
    final pusher = Pusher(
        appId: 'test',
        pushkey: 'opaque-key',
        kind: 'http',
        appDisplayName: 'test',
        deviceDisplayName: 'test',
        lang: 'en',
        data: PusherData(url: Uri.parse('https://test/push')));
    late Future<void> Function() cleanup;
    await matrix.registerAppHomeResource(
        open: (value) async {
          capability = value;
          final gateway = value.createPusherGateway();
          await gateway.create(pusher);
          cleanup = () async {
            await expectLater(
                gateway.delete(PusherId(appId: 'test', pushkey: 'other')),
                throwsStateError);
            await gateway.delete(pusher);
          };
        },
        close: () => cleanup());
    await matrix.suspend().timeout(const Duration(seconds: 1));
    expect(client.deletedPushers, ['opaque-key']);
    expect(() => capability.createPusherGateway(), throwsStateError);
  });

  test('clear and account changes cannot reuse previous decrypted preview',
      () async {
    final client = SnapshotClient();
    final room = SnapshotRoom(id: '!shared:test', client: client, joined: true);
    room.snapshotEvent = Event(
        room: room,
        type: EventTypes.Encrypted,
        eventId: r'$same',
        senderId: '@peer:test',
        originServerTs: DateTime.utc(2026),
        content: {'can_request_session': true});
    client.snapshotRooms.add(room);
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), clearClientData: (_) async {});
    await matrix.conversations.snapshot();
    client.onEvent.add(EventUpdate(
        roomID: room.id,
        type: EventUpdateType.decryptedTimelineQueue,
        content: {
          'event_id': r'$same',
          'type': EventTypes.Message,
          'sender': '@peer:test',
          'origin_server_ts': 1,
          'content': {
            'msgtype': MessageTypes.Text,
            'body': 'old account secret'
          }
        }));
    await Future<void>.delayed(Duration.zero);
    expect((await matrix.conversations.snapshot()).rooms.single.lastEvent!.body,
        'old account secret');
    client.matrixUserId = '@other:test';
    expect((await matrix.conversations.snapshot()).rooms.single.lastEvent!.body,
        isNot('old account secret'));
    client.matrixUserId = '@me:test';
    await matrix.clearLocalChatData();
    // Late event callbacks from the closed SDK must not repopulate plaintext.
    client.onEvent.add(EventUpdate(
        roomID: room.id,
        type: EventUpdateType.decryptedTimelineQueue,
        content: {
          'event_id': r'$same',
          'type': EventTypes.Message,
          'content': {'msgtype': MessageTypes.Text, 'body': 'late old secret'}
        }));
    await Future<void>.delayed(Duration.zero);
    expect(matrix.debugDecryptedPreviewCount, 0);
  });

  test('owned media bytes and thumbnails preserve Uint8List identity',
      () async {
    final client = EncryptedMediaTrackingClient('bytes');
    final room = MediaTrackingRoom(id: '!room:test', client: client);
    client.roomOverride = room;
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    final lease = await matrix.openRoomLease(room.id);
    final bytes = Uint8List.fromList([1, 2, 3]);
    final thumbnail = Uint8List.fromList([4, 5]);
    await lease.sendEncryptedMedia(room.id, bytes, 'video/mp4',
        thumbnailBytes: thumbnail);
    expect(identical(room.sentFile!.bytes, bytes), isTrue);
    expect(identical(room.sentThumbnail!.bytes, thumbnail), isTrue);
    await matrix.sendEncryptedMedia(room.id, bytes, 'image/gif');
    expect(identical(room.sentFile!.bytes, bytes), isTrue);
  });

  test('core sync leaves group invites pending for business preference gate',
      () async {
    final client = SnapshotClient();
    client.snapshotRooms
        .add(SnapshotRoom(id: '!invite:test', client: client, joined: false));
    final matrix =
        MatrixSdkE2eeClient(client, homeserver: Uri.parse('https://test'));
    // No UI auto-join authorization is provided (setting disabled/unavailable).
    await matrix.sync();
    expect(client.joinCalls, 0);
    expect((await matrix.conversations.pendingGroupInvites()).single.id,
        '!invite:test');
  });

  test('home capability reattaches before resumed client is published',
      () async {
    final first = SnapshotClient();
    final resumed = SnapshotClient();
    final matrix = MatrixSdkE2eeClient(first,
        homeserver: Uri.parse('https://test'),
        suspendClient: (_) async {},
        resumeClient: () async => resumed);
    final handles = <MatrixAppHomeCapability>[];
    await matrix.registerAppHomeResource(
        open: (capability) async {
          handles.add(capability);
          capability.createPusherGateway();
          await capability.createUnreadSnapshotSource().load();
        },
        close: () async {});
    await matrix.suspend();
    await matrix.sync().timeout(const Duration(seconds: 1));
    expect(handles, hasLength(2));
    expect(() => handles.first.createPusherGateway(), throwsStateError);
    expect(handles.last.createPusherGateway, returnsNormally);
  });

  test('clear racing backup key creation cannot retain recovery secret',
      () async {
    final store = DeferredBackupStore();
    final client = BackupRaceClient(DeferredEncryption(store));
    final matrix = MatrixSdkE2eeClient(client,
        homeserver: Uri.parse('https://test'), clearClientData: (_) async {});
    final backup = matrix.backupKeysToEncryptedStore();
    await store.started.future;
    final rejected = expectLater(backup, throwsStateError);
    final clear = matrix.clearLocalChatData();
    final handle = BackupHandle();
    store.result.complete(handle);
    await rejected;
    await clear;
    expect(matrix.lastRecoveryKey, isNull);
    expect(handle.cacheCalls, 0);
  });

  test(
      'background sync cannot reopen suspended session while explicit sync can',
      () async {
    final first = LogoutTrackingClient('active');
    final resumed = LogoutTrackingClient('resumed');
    var resumeCalls = 0;
    final matrix = MatrixSdkE2eeClient(first,
        homeserver: Uri.parse('https://test'),
        suspendClient: (_) async {}, resumeClient: () async {
      resumeCalls++;
      return resumed;
    });
    await matrix.syncIfActive();
    expect(first.syncCalls, 1);
    await matrix.suspend();
    await expectLater(matrix.syncIfActive(), throwsStateError);
    expect(resumeCalls, 0);
    expect(matrix.debugHasActiveClient, isFalse);
    await matrix.sync();
    expect(resumeCalls, 1);
    expect(resumed.syncCalls, 1);
    await matrix.syncIfActive();
    expect(resumed.syncCalls, 2);
  });

  test('conversation capability returns only immutable snapshot data',
      () async {
    final client = LogoutTrackingClient('old');
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
    );

    final snapshot = await matrix.conversations.snapshot();
    expect(snapshot, isA<MatrixConversationSnapshot>());
    expect(snapshot.rooms, isEmpty);
    expect(snapshot.rooms.clear, throwsUnsupportedError);
  });

  test('managed client stream detaches on suspend and rebuilds on resume',
      () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    final oldEvents = StreamController<MatrixSasRequestHandle>.broadcast();
    final resumedEvents = StreamController<MatrixSasRequestHandle>.broadcast();
    final received = <String>[];
    var sourceGeneration = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async => resumedClient,
    );
    final subscription = await matrix.subscribeSasRequests(
      testSource: () =>
          sourceGeneration++ == 0 ? oldEvents.stream : resumedEvents.stream,
      onData: (_) => received.add(
        sourceGeneration == 1 ? 'before-suspend' : 'after-resume',
      ),
    );

    oldEvents.add(const _TestSasRequest('before-suspend'));
    await Future<void>.delayed(Duration.zero);
    await matrix.suspend();
    oldEvents.add(const _TestSasRequest('after-suspend'));
    await Future<void>.delayed(Duration.zero);
    await matrix.sync();
    resumedEvents.add(const _TestSasRequest('after-resume'));
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
    var opens = 0;
    await matrix.registerVerificationLifecycle(
      open: () async => events.add('open:${opens++ == 0 ? 'old' : 'resumed'}'),
      close: () async => events.add('close'),
      revoke: () {},
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
    lease.setOnRevoked(() {
      events.add('revoke');
    });
    lease.bindOwnerDrain(() async {
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
    expect(() => lease.roomInfo, throwsStateError);
  });

  test('room lease owns encrypted media sends and rejects them after revoke',
      () async {
    final client = EncryptedMediaTrackingClient('old');
    final room = MediaTrackingRoom(
      id: '!room:matrix.test',
      client: client,
    );
    client.roomOverride = room;
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
    );
    final lease = await matrix.openRoomLease(room.id);

    expect(
      await lease.sendEncryptedMedia(room.id, [1, 2, 3], 'image/png'),
      r'$event',
    );
    expect(room.sentFile?.bytes, [1, 2, 3]);
    expect(room.sentFile?.mimeType, 'image/png');

    await matrix.suspend();
    await expectLater(
      lease.sendEncryptedMedia(room.id, [4], 'image/png'),
      throwsStateError,
    );
  });

  test('room lease reentrant cancellation cannot deadlock suspension',
      () async {
    final client = LogoutTrackingClient('old');
    client.roomOverride = Room(id: '!room:matrix.test', client: client);
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
    );
    final lease = await matrix.openRoomLease('!room:matrix.test');
    lease.setOnRevoked(lease.cancel);

    await matrix.suspend().timeout(const Duration(milliseconds: 100));

    expect(() => lease.roomInfo, throwsStateError);
  });

  test('room lease drain failure retains the active database for retry',
      () async {
    final client = LogoutTrackingClient('old');
    client.roomOverride = Room(id: '!room:matrix.test', client: client);
    final events = <String>[];
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async => events.add('suspend'),
    );
    final lease = await matrix.openRoomLease('!room:matrix.test');
    lease.setOnRevoked(() => throw StateError('sensitive callback detail'));
    lease.bindOwnerDrain(
      () async => throw StateError('sensitive route detail'),
    );

    await expectLater(
      matrix.suspend(),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_ROOM_LEASE_DRAIN_FAILED',
      )),
    );

    expect(events, isEmpty);
    expect(matrix.debugHasActiveClient, isTrue);
    lease.bindOwnerDrain(() async {});
    await matrix.suspend();
    expect(events, ['suspend']);
  });

  test('room lease drain timeout retains the active database for retry',
      () async {
    final client = LogoutTrackingClient('old');
    client.roomOverride = Room(id: '!room:matrix.test', client: client);
    final events = <String>[];
    final neverDrains = Completer<void>();
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      lifecycleDrainTimeout: const Duration(milliseconds: 10),
      suspendClient: (_) async => events.add('suspend'),
    );
    final lease = await matrix.openRoomLease('!room:matrix.test');
    lease.bindOwnerDrain(() => neverDrains.future);

    await expectLater(
      matrix.suspend(),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_ROOM_LEASE_DRAIN_TIMEOUT',
      )),
    );

    expect(events, isEmpty);
    expect(matrix.debugHasActiveClient, isTrue);
    lease.bindOwnerDrain(() async {});
    await matrix.suspend();
    expect(events, ['suspend']);
  });

  test('room lease timeout emits an allowlisted security event', () async {
    final client = LogoutTrackingClient('old');
    client.roomOverride = Room(id: '!room:matrix.test', client: client);
    final events = <String>[];
    final matrix = MatrixSdkE2eeClient(
      client,
      homeserver: Uri.parse('https://matrix.test'),
      lifecycleDrainTimeout: const Duration(milliseconds: 10),
      suspendClient: (_) async {},
      securityLogger: MatrixSecurityLogger(
        traceId: () => 'trace-test',
        sink: events.add,
      ),
    );
    final lease = await matrix.openRoomLease('!room:matrix.test');
    final neverDrains = Completer<void>();
    lease.bindOwnerDrain(() => neverDrains.future);

    await expectLater(matrix.suspend(), throwsStateError);

    expect(events, [
      '{"trace_id":"trace-test","stage":"room_lease_drain",'
          '"outcome":"timeout","event_code":"E2EE_ROOM_LEASE_DRAIN_TIMEOUT"}',
    ]);
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
    expect(matrix.debugHasActiveClient, isFalse);
  });

  test('login sync failure suspends without deleting Matrix identity or key',
      () async {
    final secureStore = SecureSessionStore(MemoryStore());
    final oldClient = LogoutTrackingClient(
      'old',
      loggedIn: true,
      matrixUserId: '@alice:matrix.test',
      matrixDeviceId: 'DEVICE-A',
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/login'));
        return http.Response(
            jsonEncode({
              'access_token': 'replacement-token',
              'user_id': '@alice:matrix.test',
              'device_id': 'DEVICE-A',
            }),
            200,
            headers: {'content-type': 'application/json'});
      }),
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
      throwsA(isA<LoginStageException>()
          .having((e) => e.diagnosticCode, 'stage', 'L05')),
    );

    expect(events, ['dispose:old']);
    expect(oldClient.logoutCalls, 0);
    expect(matrix.userId, '@alice:matrix.test');
    expect(matrix.deviceId, 'DEVICE-A');
    expect(await secureStore.matrixDatabaseKey(), oldKey);
    expect(business.logouts, 1);
  });
  test('revoked session cannot reopen a room lease', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    var resumeCalls = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async {
        resumeCalls++;
        return resumedClient;
      },
    );

    await matrix.suspend();

    await expectLater(
      matrix.openRoomLease('!room:matrix.test'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_LIFECYCLE_ACCESS_REVOKED',
      )),
    );
    expect(resumeCalls, 0);
  });

  test('revoked session cannot register a home resource', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    var resumeCalls = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async {
        resumeCalls++;
        return resumedClient;
      },
    );

    await matrix.suspend();

    await expectLater(
      matrix.registerAppHomeResource(
        open: (_) async {},
        close: () async {},
      ),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_LIFECYCLE_ACCESS_REVOKED',
      )),
    );
    expect(resumeCalls, 0);
  });

  test('revoked session cannot register a subscription', () async {
    final oldClient = LogoutTrackingClient('old');
    final resumedClient = LogoutTrackingClient('resumed');
    var resumeCalls = 0;
    final matrix = MatrixSdkE2eeClient(
      oldClient,
      homeserver: Uri.parse('https://matrix.test'),
      suspendClient: (_) async {},
      resumeClient: () async {
        resumeCalls++;
        return resumedClient;
      },
    );

    await matrix.suspend();

    await expectLater(
      matrix.subscribeSasRequests(onData: (_) {}),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'E2EE_LIFECYCLE_ACCESS_REVOKED',
      )),
    );
    expect(resumeCalls, 0);
  });
}
