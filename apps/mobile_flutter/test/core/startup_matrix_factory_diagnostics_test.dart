import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/core/startup_failure_metadata.dart';
import 'package:liuhetong_mobile/features/matrix/local_identity_preflight.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'session_store_test.dart' show MemorySecureKeyValueStore;

class _EmptyReader implements MatrixLocalIdentityReader {
  @override
  Future<bool> exists(String path) async => false;
  @override
  Future<MatrixLocalIdentityRecord> read(String path, String cipher) async =>
      throw StateError('must not read missing database');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('database key observer preserves original exception type and value',
      () async {
    final failure = PlatformException(code: '-34018', message: 'PRIVATE-KEY');
    final memory = MemorySecureKeyValueStore()
      ..beforeWrite = (_, __) async => throw failure;
    final captured = <StartupFailureMetadata>[];
    final factory = MatrixClientFactory(
      sessionStore: SecureSessionStore(memory),
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/safe/app-support',
      localIdentityPreflight:
          MatrixLocalIdentityPreflight(reader: _EmptyReader()),
    );
    await expectLater(
        factory.create(onFailure: captured.add), throwsA(same(failure)));
    expect(captured.single.boundary, StartupFailureBoundary.databaseKey);
    expect(
        captured.single.nativeStatus, StartupNativeStatus.missingEntitlement);
    expect(memory.attemptedDeletes, isEmpty);
  });

  test('migration observer preserves disposer and original exception',
      () async {
    const failure = FormatException('PRIVATE-DATABASE');
    final captured = <StartupFailureMetadata>[];
    var disposals = 0;
    final factory = MatrixClientFactory(
      sessionStore: SecureSessionStore(MemorySecureKeyValueStore()),
      homeserver: Uri.parse('https://matrix.test'),
      supportDirectoryPath: () async => '/safe/app-support',
      localIdentityPreflight:
          MatrixLocalIdentityPreflight(reader: _EmptyReader()),
      opener: (
              {required clientName,
              required databasePath,
              required cipher}) async =>
          Client(clientName),
      clientMigrator: (_, __) async => throw failure,
      disposer: (_) async {
        disposals++;
      },
    );
    await expectLater(
        factory.create(onFailure: captured.add), throwsA(same(failure)));
    expect(captured.single.boundary, StartupFailureBoundary.clientMigration);
    expect(disposals, 1);
  });
}
