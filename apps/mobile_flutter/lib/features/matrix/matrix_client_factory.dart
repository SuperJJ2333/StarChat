import 'dart:convert';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/matrix_local_binding.dart';
import '../../core/session_store.dart';
import 'matrix_e2ee_client.dart';

typedef MatrixClientOpener = Future<Client> Function({
  required String clientName,
  required String databasePath,
  required String cipher,
});
typedef MatrixClientDisposer = Future<void> Function(Client client);
typedef MatrixDatabaseDeleter = Future<void> Function(String path);
typedef MatrixClientMigrator = Future<void> Function(
    Client client, Uri homeserver);

final class MatrixClientFactory {
  MatrixClientFactory({
    required this.sessionStore,
    required this.homeserver,
    Future<String> Function()? supportDirectoryPath,
    MatrixClientOpener? opener,
    MatrixClientDisposer? disposer,
    MatrixDatabaseDeleter? databaseDeleter,
    MatrixClientMigrator? clientMigrator,
    String? Function(Client client)? fingerprintReader,
    String Function()? databaseGenerationFactory,
  })  : supportDirectoryPath = supportDirectoryPath ?? _defaultSupportPath,
        opener = opener ?? _openPersistentClient,
        disposer = disposer ?? _disposeClient,
        databaseDeleter = databaseDeleter ?? _deleteDatabase,
        clientMigrator = clientMigrator ?? _migrateHomeserver,
        fingerprintReader = fingerprintReader ?? _readFingerprint,
        databaseGenerationFactory =
            databaseGenerationFactory ?? _newDatabaseGeneration;

  static const clientName = 'liuhetong_mobile';
  static const databaseFileName = 'liuhetong_matrix.sqlite';

  final SecureSessionStore sessionStore;
  final Uri homeserver;
  final Future<String> Function() supportDirectoryPath;
  final MatrixClientOpener opener;
  final MatrixClientDisposer disposer;
  final MatrixDatabaseDeleter databaseDeleter;
  final MatrixClientMigrator clientMigrator;
  final String? Function(Client client) fingerprintReader;
  final String Function() databaseGenerationFactory;
  String? _unboundDatabaseGeneration;

  Future<Client> create() async {
    final directory = await supportDirectoryPath();
    final cipher = await sessionStore.matrixDatabaseKey();
    final client = await opener(
      clientName: clientName,
      databasePath: p.join(directory, databaseFileName),
      cipher: cipher,
    );
    await clientMigrator(client, homeserver);
    return client;
  }

  Future<MatrixClientContinuityMetadata> continuityMetadata(
      Client client) async {
    final binding = await sessionStore.matrixBinding();
    final generation = binding?.databaseGeneration ??
        (_unboundDatabaseGeneration ??= databaseGenerationFactory());
    if (!client.isLogged()) {
      return MatrixClientContinuityMetadata(
        isLoggedIn: false,
        userId: null,
        deviceId: null,
        ed25519Fingerprint: null,
        databaseGeneration: generation,
      );
    }
    final userId = client.userID;
    final deviceId = client.deviceID;
    final fingerprint = fingerprintReader(client);
    if (userId == null ||
        deviceId == null ||
        fingerprint == null ||
        fingerprint.isEmpty) {
      throw StateError('Matrix continuity identity is unavailable');
    }
    final expectedHomeserver = homeserver.toString();
    if (binding == null) {
      await sessionStore.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: userId,
        deviceId: deviceId,
        homeserver: expectedHomeserver,
        databaseGeneration: generation,
        ed25519Fingerprint: fingerprint,
      ));
    } else if (binding.matrixUserId != userId ||
        binding.deviceId != deviceId ||
        binding.homeserver != expectedHomeserver) {
      throw StateError('Matrix client does not match the local binding');
    } else if (binding.ed25519Fingerprint == null) {
      await sessionStore.saveMatrixBinding(MatrixLocalBinding(
        version: 2,
        matrixUserId: binding.matrixUserId,
        deviceId: binding.deviceId,
        homeserver: binding.homeserver,
        databaseGeneration: binding.databaseGeneration,
        ed25519Fingerprint: fingerprint,
      ));
    } else if (binding.ed25519Fingerprint != fingerprint) {
      throw StateError('Matrix client does not match the local binding');
    }
    return MatrixClientContinuityMetadata(
      isLoggedIn: true,
      userId: userId,
      deviceId: deviceId,
      ed25519Fingerprint: fingerprint,
      databaseGeneration: generation,
    );
  }

  /// Closes the active handle while retaining the encrypted database, its key,
  /// and all local Olm/Megolm sessions for a later [create].
  Future<void> suspend(Client client) => disposer(client);

  Future<void> clearLocalChatData(Client? client) async {
    final directory = await supportDirectoryPath();
    final databasePath = p.join(directory, databaseFileName);
    if (client != null) {
      try {
        await client.logout();
      } catch (_) {
        // Local deletion remains available while the homeserver is offline.
      } finally {
        await disposer(client);
      }
    }
    await databaseDeleter(databasePath);
    await sessionStore.clearMatrixIdentity();
    _unboundDatabaseGeneration = null;
  }

  static Future<String> _defaultSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

  static Future<void> _disposeClient(Client client) => client.dispose();

  static Future<void> _deleteDatabase(String path) async {
    final databaseFactory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    await databaseFactory.deleteDatabase(path);
  }

  static String? _readFingerprint(Client client) =>
      client.encryption?.fingerprintKey;

  static String _newDatabaseGeneration() => base64UrlEncode(
        List<int>.generate(24, (_) => Random.secure().nextInt(256)),
      );

  /// Retains the encrypted local database, sessions and room history while
  /// replacing only the persisted Matrix server endpoint.
  static Future<void> _migrateHomeserver(Client client, Uri homeserver) async {
    if (!client.isLogged() || client.homeserver == homeserver) return;
    final token = client.accessToken;
    final userId = client.userID;
    final deviceId = client.deviceID;
    final deviceName = client.deviceName;
    if (token == null ||
        userId == null ||
        deviceId == null ||
        deviceName == null) {
      return;
    }
    // The SDK has already initialized this persistent client. Re-initializing
    // would reject a logged-in client and can discard in-memory E2EE state.
    // Update only the endpoint record that the next sync consumes.
    client.homeserver = homeserver;
    final persistedClient = await client.database?.getClient(client.clientName);
    await client.database?.updateClient(
      homeserver.toString(),
      token,
      client.accessTokenExpiresAt,
      persistedClient?.tryGet<String>('refresh_token'),
      userId,
      deviceId,
      deviceName,
      client.prevBatch,
      client.encryption?.pickledOlmAccount,
    );
  }

  static Future<Client> _openPersistentClient({
    required String clientName,
    required String databasePath,
    required String cipher,
  }) async {
    final databaseFactory = createDatabaseFactoryFfi(
      ffiInit: SQfLiteEncryptionHelper.ffiInit,
    );
    final encryption = SQfLiteEncryptionHelper(
      factory: databaseFactory,
      path: databasePath,
      cipher: cipher,
    );
    await encryption.ensureDatabaseFileEncrypted();
    final client = Client(
      clientName,
      verificationMethods: {
        KeyVerificationMethod.emoji,
        KeyVerificationMethod.numbers,
      },
      databaseBuilder: (_) async {
        final database = await databaseFactory.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(onConfigure: encryption.applyPragmaKey),
        );
        final matrixDatabase = MatrixSdkDatabase(
          clientName,
          database: database,
          sqfliteFactory: databaseFactory,
        );
        await matrixDatabase.open();
        return matrixDatabase;
      },
    );
    await client.init();
    return client;
  }
}
