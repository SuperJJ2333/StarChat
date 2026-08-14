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

final class MatrixClientFactory {
  MatrixClientFactory({
    required this.sessionStore,
    Future<String> Function()? supportDirectoryPath,
    MatrixClientOpener? opener,
  })  : supportDirectoryPath = supportDirectoryPath ?? _defaultSupportPath,
        opener = opener ?? _openPersistentClient;

  static const clientName = 'liuhetong_mobile';
  static const databaseFileName = 'liuhetong_matrix.sqlite';

  final SecureSessionStore sessionStore;
  final Future<String> Function() supportDirectoryPath;
  final MatrixClientOpener opener;

  Future<Client> create() async {
    final directory = await supportDirectoryPath();
    final cipher = await sessionStore.matrixDatabaseKey();
    return opener(
      clientName: clientName,
      databasePath: p.join(directory, databaseFileName),
      cipher: cipher,
    );
  }

  static Future<String> _defaultSupportPath() async =>
      (await getApplicationSupportDirectory()).path;

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
