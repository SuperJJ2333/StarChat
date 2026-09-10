import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_e2ee_client.dart';
import '../../core/account_chat_store_test.dart' show binding;
import '../../core/session_store_test.dart' show MemorySecureKeyValueStore;
import 'matrix_client_factory_test.dart' show LogoutTrackingClient;

const _home = 'https://matrix.example';

MatrixClientFactory _factory(SecureSessionStore store) => MatrixClientFactory(
      sessionStore: store,
      homeserver: Uri.parse(_home),
      supportDirectoryPath: () async => '/private/support',
      clientMigrator: (_, __) async {},
      opener: (
          {required clientName,
          required databasePath,
          required cipher}) async =>
          LogoutTrackingClient(clientName),
    );

/// iOS deletes the app sandbox on uninstall but keeps the keychain, so the
/// account registry, binding and database key survive while the SQLCipher
/// database does not. Reinstalling and logging into the same account therefore
/// reopens an empty store under a scope that still claims a bound identity.
void main() {
  test('iOS uninstall leaves a binding for a store that no longer has one',
      () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    // Surviving keychain from the previous install.
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    // The sandbox was wiped, so the reopened store has no identity at all.
    final next = await _factory(store).create();
    expect(next.userID, isNull);
    expect(next.deviceID, isNull);
    expect(await store.matrixBinding(), isNotNull);

    await expectLater(
        _factory(store).continuityMetadata(next),
        throwsA(isA<StateError>().having(
            (error) => error.message,
            'message',
            'Matrix continuity identity is unavailable')));
  });

  test('a wiped store with no retained binding still reports no continuity',
      () async {
    final store = SecureSessionStore(MemorySecureKeyValueStore());
    final next = await _factory(store).create();
    final metadata = await _factory(store).continuityMetadata(next);
    expect(metadata.isLoggedIn, isFalse);
    expect(metadata.userId, isNull);
  });

  test('reinstalled first login fails in the account_storage stage', () async {
    final memory = MemorySecureKeyValueStore();
    final store = SecureSessionStore(memory);
    await store.selectMatrixAccount(_home, '@a:test');
    await store.saveMatrixBinding(binding('@a:test', 'device-A'));
    await store.matrixDatabaseKey();
    final factory = _factory(store);
    final matrix = MatrixSdkE2eeClient(
      LogoutTrackingClient('liuhetong_mobile'),
      homeserver: Uri.parse(_home),
      suspendClient: factory.suspend,
      resumeClient: factory.create,
      selectClientAccount: factory.selectAccount,
      readContinuityMetadata: factory.continuityMetadata,
    );
    await expectLater(
        matrix.selectAccount('@a:test', Uri.parse(_home)),
        throwsA(isA<StateError>().having(
            (error) => error.message,
            'message',
            'Matrix continuity identity is unavailable')));
  });
}
