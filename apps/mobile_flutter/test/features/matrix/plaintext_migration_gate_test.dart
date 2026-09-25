import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/matrix_startup_client.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:matrix/matrix.dart';

import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;

final class _PlaintextFixtureReader implements MatrixLocalIdentityReader {
  @override
  Future<bool> exists(String databasePath) async => true;

  @override
  Future<MatrixLocalIdentityRecord> read(
          String databasePath, String cipher) async =>
      const MatrixLocalIdentityRecord(
        hasRetainedData: true,
        matrixUserId: '@a:test',
        deviceId: 'device-A',
        olmAccount: 'fingerprint-@a:test',
        requiresAuthenticatedMigration: true,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy plaintext waits for Business account selection before SDK init',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    final oldCipher = await store.matrixDatabaseKey();
    var openCalls = 0;
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.example'),
      supportDirectoryPath: () async => '/fixture',
      localIdentityPreflight: MatrixLocalIdentityPreflight(
        reader: _PlaintextFixtureReader(),
        fingerprintReader: (_, pickle) async => pickle,
      ),
      clientMigrator: (_, __) async {},
      opener: ({
        required clientName,
        required databasePath,
        required cipher,
      }) async {
        openCalls++;
        expect(cipher, oldCipher);
        return Client('plaintext-fixture');
      },
    );

    final startup = await openStartupMatrixClient(
      openRetained: factory.create,
      createSafeShell: () => Client('uninitialized-shell'),
    );
    expect(startup.recoveryDeferred, isTrue);
    expect(openCalls, 0);
    expect(await store.matrixDatabaseKey(), oldCipher);

    // The application reaches this only after a Business broker grant has
    // confirmed the same MXID and homeserver.
    await factory.selectAccount('https://matrix.example', '@a:test');
    await factory.create();
    expect(openCalls, 1);
  });
}
