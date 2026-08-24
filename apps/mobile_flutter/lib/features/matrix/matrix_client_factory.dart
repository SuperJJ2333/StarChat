import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../core/session_store.dart';

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
  })  : supportDirectoryPath = supportDirectoryPath ?? _defaultSupportPath,
        opener = opener ?? _openPersistentClient,
        disposer = disposer ?? _disposeClient,
        databaseDeleter = databaseDeleter ?? _deleteDatabase,
        clientMigrator = clientMigrator ?? _migrateHomeserver;

  static const clientName = 'liuhetong_mobile';
  static const databaseFileName = 'liuhetong_matrix.sqlite';

  final SecureSessionStore sessionStore;
  final Uri homeserver;
  final Future<String> Function() supportDirectoryPath;
  final MatrixClientOpener opener;
  final MatrixClientDisposer disposer;
  final MatrixDatabaseDeleter databaseDeleter;
  final MatrixClientMigrator clientMigrator;

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

  /// Reopens the persisted client without deleting the encrypted database,
  /// its SQLCipher key, or any local Olm/Megolm sessions.
  Future<Client> reopen(Client client) async {
    await disposer(client);
    return create();
  }

  Future<Client> reset(Client client) async {
    final directory = await supportDirectoryPath();
    final databasePath = p.join(directory, databaseFileName);
    await disposer(client);
    await databaseDeleter(databasePath);
    await sessionStore.clearMatrixDatabaseKey();
    return create();
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
