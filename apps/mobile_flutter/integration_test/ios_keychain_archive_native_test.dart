import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';
import 'package:liuhetong_mobile/features/matrix/matrix_client_factory.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _homeserver = 'https://matrix.test';
const _userId = '@native-keychain:matrix.test';
const _oldKey = 'liuhetong.matrix_database_key.v1';
const _bindingKey = 'liuhetong.matrix_local_binding.v1';
const _recoveryKey = 'liuhetong.encrypted_recovery_key';
const _journalKey = 'liuhetong.matrix_archive_journal.v1';
const _indexKey = 'liuhetong.matrix_archives.v1';
const _activeKey = 'liuhetong.active_matrix_scope.v1';
const _registryKey = 'liuhetong.matrix_account_slots.v1';
const _nativeSession = MethodChannel('chatflow/ios_secure_session');

/// Inject a process interruption after the plugin has persisted the prepared
/// journal, before the archive index or active scope can change.
final class _InterruptIndexWrite
    implements SecureKeyValueStore, PeekableSecureKeyValueStore {
  _InterruptIndexWrite(this.delegate);

  final FlutterSecureKeyValueStore delegate;

  @override
  Future<String?> read(String key) => delegate.read(key);

  @override
  Future<String?> peek(String key) => delegate.peek(key);

  @override
  Future<void> write(String key, String value) {
    if (key == _indexKey) {
      throw StateError('synthetic interruption after archive journal');
    }
    return delegate.write(key, value);
  }

  @override
  Future<void> delete(String key) => delegate.delete(key);
}

Future<String?> _nativePeek(String key) =>
    _nativeSession.invokeMethod<String>('peek', {'key': key});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 2));

  testWidgets('native Keychain peek reads plugin binding and replays archive',
      (_) async {
    expect(Platform.isIOS, isTrue,
        reason: 'This gate requires a real iOS simulator and Keychain.');
    final raw = FlutterSecureKeyValueStore();
    // CI creates a disposable simulator for this test. Refuse to mutate any
    // existing installation, even if this file is run manually elsewhere.
    for (final key in [
      _oldKey,
      _bindingKey,
      _journalKey,
      _indexKey,
      _activeKey,
      _registryKey,
    ]) {
      expect(await _nativePeek(key), isNull,
          reason: 'The Keychain integration fixture requires a fresh app.');
    }
    expect(await raw.read(_recoveryKey), isNull);

    final support = await getApplicationSupportDirectory();
    final oldDatabase =
        File(p.join(support.path, MatrixClientFactory.databaseFileName));
    expect(await oldDatabase.exists(), isFalse);
    const oldBytes = <int>[13, 17, 19, 23, 29, 31];
    await oldDatabase.writeAsBytes(oldBytes, flush: true);

    final interrupted = SecureSessionStore(_InterruptIndexWrite(raw));
    final binding = MatrixLocalBinding(
      version: 2,
      matrixUserId: _userId,
      deviceId: 'ORIGINAL',
      homeserver: _homeserver,
      databaseGeneration: 'native-integration-fixture',
      ed25519Fingerprint: 'original-fingerprint',
    );
    await interrupted.saveMatrixBinding(binding);
    final originalKey = await interrupted.matrixDatabaseKey();
    await interrupted.saveEncryptedRecoveryKey('opaque-old-recovery');
    final originalBinding = jsonEncode(binding.toJson());
    // Binding is written by flutter_secure_storage, whereas peek is the
    // native read-only Security.framework query used by startup preflight.
    expect(await _nativePeek(_bindingKey), originalBinding);
    expect(await _nativePeek(_oldKey), originalKey);
    expect(await raw.read(_recoveryKey), 'opaque-old-recovery');

    final original =
        await interrupted.peekAccountMatrixIdentity(_homeserver, _userId);
    await expectLater(
      interrupted.prepareFreshDeviceForConfirmedRecovery(
        expectedHomeserver: _homeserver,
        expectedUserId: _userId,
        expectedSnapshot: original,
        scopeHasDatabaseFiles: (scope) async => File(p.join(
          support.path,
          'liuhetong_matrix_$scope.sqlite',
        )).exists(),
      ),
      throwsStateError,
    );

    // The journal is a real plugin-written Keychain item. Native peek must
    // see it without any SDK init, Keychain migration, or destructive read.
    final prepared = await _nativePeek(_journalKey);
    expect(prepared, contains('"phase":"prepared"'));
    expect(await raw.read(_journalKey), prepared);
    expect(await _nativePeek(_indexKey), isNull);
    expect(await oldDatabase.readAsBytes(), oldBytes);

    // A new SessionStore models relaunch. Recovery must replay the durable
    // journal using the same native Keychain and preserve the old identity.
    final relaunched = SecureSessionStore(FlutterSecureKeyValueStore());
    await relaunched.recoverPendingMatrixArchive(
      expectedHomeserver: _homeserver,
      expectedUserId: _userId,
    );
    final freshScope =
        await relaunched.confirmedFreshDeviceScope(_homeserver, _userId);
    expect(freshScope, matches(RegExp(r'^[a-f0-9]{64}$')));
    final old = await relaunched.peekMatrixIdentityAtScope('');
    final fresh = await relaunched.peekMatrixIdentityAtScope(freshScope!);
    expect(old.binding, binding);
    expect(old.databaseKey, originalKey);
    expect(fresh.binding, isNull);
    expect(fresh.databaseKey, isNotNull);
    expect(fresh.databaseKey, isNot(originalKey));
    expect(await _nativePeek(_bindingKey), originalBinding);
    expect(await _nativePeek(_oldKey), originalKey);
    expect(await raw.read(_recoveryKey), 'opaque-old-recovery');
    expect(await _nativePeek(_journalKey), isNull);
    expect(await _nativePeek(_indexKey), contains('"kind":"fresh_device"'));
    expect(await oldDatabase.readAsBytes(), oldBytes);
  });
}
