import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_startup_client.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:matrix/matrix.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;

void main() {
  test('pending archive reaches safe shell without creating diagnostic salt',
      () async {
    final memory = MemorySecureKeyValueStore();
    memory.values['liuhetong.matrix_archive_journal.v1'] = '{}';
    final store = SecureSessionStore(memory);
    final salt = await loadStartupDiagnosticSalt(store);
    expect(salt, isNull);
    expect(memory.values.containsKey('liuhetong.diagnostic_salt.v1'), isFalse);
    final factory = MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/unused',
      opener: ({
        required clientName,
        required databasePath,
        required cipher,
      }) async =>
          throw StateError('SDK must remain closed'),
    );
    final startup = await openStartupMatrixClient(
      openRetained: factory.create,
      createSafeShell: () => Client('safe-archive-shell'),
    );
    expect(startup.recoveryDeferred, isTrue);
    expect(startup.client.isLogged(), isFalse);
    await validateLocalLoginStorageForAuthentication(store);
    expect(memory.values['liuhetong.matrix_archive_journal.v1'], '{}');
  });
  test('conclusive identity failure builds only an uninitialized safe shell',
      () async {
    var fallbackCalls = 0;
    final result = await openStartupMatrixClient(
      openRetained: () async =>
          throw const MatrixLocalIdentityPreflightException(
        MatrixLocalIdentityCause.fingerprintMismatch,
        canCreateNewDevice: true,
      ),
      createSafeShell: () {
        fallbackCalls++;
        return Client('safe-shell');
      },
    );

    expect(result.recoveryDeferred, isTrue);
    expect(result.client.isLogged(), isFalse);
    expect(fallbackCalls, 1);
  });

  test('uncertain local state stays on retry gate without safe-shell login',
      () async {
    var fallbackCalls = 0;
    await expectLater(
      openStartupMatrixClient(
        openRetained: () async =>
            throw const MatrixLocalIdentityPreflightException(
                MatrixLocalIdentityCause.unreadable),
        createSafeShell: () {
          fallbackCalls++;
          return Client('should-not-open');
        },
      ),
      throwsA(isA<MatrixLocalIdentityPreflightException>()),
    );
    expect(fallbackCalls, 0);
  });

  test('verified original in another scope defers opening until Business auth',
      () async {
    var fallbackCalls = 0;
    final result = await openStartupMatrixClient(
      openRetained: () async =>
          throw const MatrixLocalIdentityPreflightException(
              MatrixLocalIdentityCause.originalIdentityElsewhere),
      createSafeShell: () {
        fallbackCalls++;
        return Client('original-recovery-shell');
      },
    );

    expect(result.recoveryDeferred, isTrue);
    expect(result.client.isLogged(), isFalse);
    expect(fallbackCalls, 1);
  });

  test('unfinished archive journal defers replay until Business auth',
      () async {
    var fallbackCalls = 0;
    final result = await openStartupMatrixClient(
      openRetained: () async =>
          throw const MatrixLocalIdentityPreflightException(
              MatrixLocalIdentityCause.recoveryPending),
      createSafeShell: () {
        fallbackCalls++;
        return Client('journal-recovery-shell');
      },
    );

    expect(result.recoveryDeferred, isTrue);
    expect(result.client.isLogged(), isFalse);
    expect(fallbackCalls, 1);
  });

  test('safe shell never calls ordinary continuity reader on old binding',
      () async {
    final safe = Client('safe-shell');
    final startup = StartupMatrixClient(safe, recoveryDeferred: true);
    var reads = 0;
    final guarded = guardStartupContinuityReader<int>(startup, (_) async {
      reads++;
      return 7;
    });

    await expectLater(guarded(safe), throwsStateError);
    expect(reads, 0);
    expect(await guarded(Client('new-device')), 7);
    expect(reads, 1);
  });
}
