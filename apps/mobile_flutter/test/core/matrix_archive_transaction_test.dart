import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';
import 'package:liuhetong_mobile/core/session_store.dart';

const _homeserver = 'https://matrix.test';
const _userId = '@old:matrix.test';
const _keyName = 'liuhetong.matrix_database_key.v1';
const _bindingName = 'liuhetong.matrix_local_binding.v1';
const _recoveryName = 'liuhetong.encrypted_recovery_key';
const _indexName = 'liuhetong.matrix_archives.v1';
const _journalName = 'liuhetong.matrix_archive_journal.v1';
const _registryName = 'liuhetong.matrix_account_slots.v1';
const _activeName = 'liuhetong.active_matrix_scope.v1';

final class _FaultStore implements SecureKeyValueStore {
  final values = <String, String>{};
  final writes = <String>[];
  final deletes = <String>[];
  String? failWriteKey;
  String? failWritePrefix;
  String? failDeleteKey;
  bool failAfterMutation = false;
  int? failWriteOrdinal;
  String? corruptWriteKey;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    final selected = failWriteKey == key ||
        (failWritePrefix != null && key.startsWith(failWritePrefix!));
    final shouldFail = selected &&
        (failWriteOrdinal == null ||
            writes.where((written) => written == key).length ==
                failWriteOrdinal);
    if (shouldFail && !failAfterMutation) {
      throw StateError('synthetic write fault');
    }
    values[key] = corruptWriteKey == key ? '{corrupt' : value;
    if (shouldFail && failAfterMutation) {
      throw StateError('synthetic write fault');
    }
  }

  @override
  Future<void> delete(String key) async {
    deletes.add(key);
    if (failDeleteKey == key && !failAfterMutation) {
      throw StateError('synthetic delete fault');
    }
    values.remove(key);
    if (failDeleteKey == key && failAfterMutation) {
      throw StateError('synthetic delete fault');
    }
  }
}

MatrixLocalBinding _oldBinding() => MatrixLocalBinding(
      version: 2,
      matrixUserId: _userId,
      deviceId: 'ORIGINAL',
      homeserver: _homeserver,
      databaseGeneration: 'old-generation',
      ed25519Fingerprint: 'original-fingerprint',
    );

Future<(SecureSessionStore, MatrixStoredIdentitySnapshot)> _retained(
    _FaultStore raw) async {
  final store = SecureSessionStore(raw);
  await store.saveMatrixBinding(_oldBinding());
  await store.matrixDatabaseKey();
  await store.saveEncryptedRecoveryKey('opaque-old-recovery');
  return (store, await store.peekAccountMatrixIdentity(_homeserver, _userId));
}

Future<String> _prepare(
        SecureSessionStore store, MatrixStoredIdentitySnapshot snapshot) =>
    store.prepareFreshDeviceForConfirmedRecovery(
      expectedHomeserver: _homeserver,
      expectedUserId: _userId,
      expectedSnapshot: snapshot,
      scopeHasDatabaseFiles: (_) async => false,
    );

Future<void> _replay(SecureSessionStore store) =>
    store.recoverPendingMatrixArchive(
      expectedHomeserver: _homeserver,
      expectedUserId: _userId,
    );

void main() {
  test('confirmed recovery archives original before mapping a pristine scope',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    final oldValues = Map<String, String>.from(raw.values);

    final newScope = await _prepare(store, oldSnapshot);

    expect(newScope, matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(raw.values[_bindingName], oldValues[_bindingName]);
    expect(raw.values[_keyName], oldValues[_keyName]);
    expect(raw.values[_recoveryName], oldValues[_recoveryName]);
    expect(raw.values['$_keyName.$newScope'], isNot(oldValues[_keyName]));
    expect(raw.values[_activeName], newScope);
    expect(raw.values[_journalName], isNull);
    expect(raw.values[_indexName], contains('"old_scope":""'));
    expect(raw.values[_indexName], contains('"new_scope":"$newScope"'));
    expect(raw.values[_indexName], isNot(contains(_userId)));
    expect(raw.values[_indexName], isNot(contains(oldValues[_keyName])));
    expect(raw.writes.indexOf(_journalName),
        lessThan(raw.writes.indexOf(_indexName)));
    expect(raw.writes.indexOf(_indexName),
        lessThan(raw.writes.indexOf('$_keyName.$newScope')));
    expect(raw.writes.indexOf('$_keyName.$newScope'),
        lessThan(raw.writes.indexOf(_registryName)));
    expect(raw.writes.indexOf(_registryName),
        lessThan(raw.writes.indexOf(_activeName)));
  });

  test(
      'unbound confirmed scope remains discoverable after another account is selected',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    final newScope = await _prepare(store, oldSnapshot);
    expect(
        await store.confirmedFreshDeviceScope(_homeserver, _userId), newScope);

    await store.selectMatrixAccount(_homeserver, '@other:matrix.test');
    expect((await store.peekActiveMatrixIdentity()).scope, isNot(newScope));
    expect(
        await store.confirmedFreshDeviceScope(_homeserver, _userId), newScope);
    expect(
        await store.confirmedFreshDeviceScope(
            _homeserver, '@other:matrix.test'),
        isNull);

    final retained =
        await store.peekAccountMatrixIdentity(_homeserver, _userId);
    expect(retained.scope, newScope);
    await store.selectMatrixAccount(_homeserver, _userId,
        expectedSnapshot: retained);
    expect((await store.peekActiveMatrixIdentity()).scope, newScope);
    expect(raw.values[_bindingName], isNotNull);
    expect(raw.values[_keyName], isNotNull);
  });

  for (final failureKey in [
    _journalName,
    _indexName,
    '$_keyName.',
    _registryName,
    _activeName,
  ]) {
    for (final afterMutation in [false, true]) {
      test('replay after $failureKey fault (after write: $afterMutation)',
          () async {
        final raw = _FaultStore();
        final (store, oldSnapshot) = await _retained(raw);
        final oldValues = Map<String, String>.from(raw.values);
        if (failureKey.endsWith('.')) {
          raw.failWritePrefix = failureKey;
        } else {
          raw.failWriteKey = failureKey;
        }
        raw.failAfterMutation = afterMutation;

        await expectLater(_prepare(store, oldSnapshot), throwsStateError);
        raw.failWriteKey = null;
        raw.failWritePrefix = null;
        if (raw.values[_journalName] != null) {
          await expectLater(store.peekActiveMatrixIdentity(),
              throwsA(isA<MatrixArchiveRecoveryPending>()));
          final restarted = SecureSessionStore(raw);
          await _replay(restarted);
          final active = await restarted.peekActiveMatrixIdentity();
          expect(active.scope, matches(RegExp(r'^[a-f0-9]{64}$')));
          expect(active.binding, isNull);
          expect(active.databaseKey, isNotNull);
          expect(raw.values[_journalName], isNull);
          expect(raw.values[_indexName], isNotNull);
        } else {
          expect(failureKey, _journalName);
          expect(afterMutation, isFalse);
        }
        expect(raw.values[_keyName], oldValues[_keyName]);
        expect(raw.values[_bindingName], oldValues[_bindingName]);
        expect(raw.values[_recoveryName], oldValues[_recoveryName]);
      });
    }
  }

  test('commit marker failure replays without allocating a second scope',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.failWriteKey = _journalName;
    raw.failWriteOrdinal = 2;
    await expectLater(_prepare(store, oldSnapshot), throwsStateError);
    final scope = raw.values[_activeName];
    raw.failWriteKey = null;

    await _replay(SecureSessionStore(raw));
    expect(raw.values[_activeName], scope);
    expect(raw.values[_journalName], isNull);
  });

  test('corrupt archive index stops before key or pointer change', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.corruptWriteKey = _indexName;

    await expectLater(_prepare(store, oldSnapshot), throwsFormatException);
    expect(raw.values[_journalName], isNotNull);
    expect(raw.values[_registryName], isNull);
    expect(raw.values[_activeName], isNull);
    expect(
        raw.values.keys.where((key) => key.startsWith('$_keyName.')), isEmpty);
  });

  test(
      'journal deletion fault is idempotent and ordinary clear preserves archive',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.failDeleteKey = _journalName;
    await expectLater(_prepare(store, oldSnapshot), throwsStateError);
    final committedScope = raw.values[_activeName];
    expect(raw.values[_journalName], isNotNull);

    raw.failDeleteKey = null;
    final restarted = SecureSessionStore(raw);
    await _replay(restarted);
    expect(raw.values[_activeName], committedScope);
    expect(await restarted.confirmedFreshDeviceScope(_homeserver, _userId),
        committedScope);
    await restarted.clearMatrixIdentity();
    expect(raw.values[_bindingName], isNotNull);
    expect(raw.values[_keyName], isNotNull);
    expect(raw.values[_recoveryName], isNotNull);
  });

  test('genuinely new installation enumerates archived scope secrets',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    final firstScope = await _prepare(store, oldSnapshot);
    raw.values['$_recoveryName.$firstScope'] = 'opaque-new-recovery';

    await store.clearInstallation();

    expect(raw.values[_bindingName], isNull);
    expect(raw.values[_keyName], isNull);
    expect(raw.values[_recoveryName], isNull);
    expect(raw.values['$_keyName.$firstScope'], isNull);
    expect(raw.values['$_recoveryName.$firstScope'], isNull);
    expect(raw.values[_indexName], isNull);
    expect(raw.values[_journalName], isNull);
  });

  test('archived scope stays enumerable after a scoped delete fault', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    await _prepare(store, oldSnapshot);
    final index = raw.values[_indexName];
    raw.failDeleteKey = _keyName;

    await expectLater(store.clearInstallation(), throwsStateError);
    expect(raw.values[_indexName], index);
    raw.failDeleteKey = null;
    await SecureSessionStore(raw).clearInstallation();
    expect(raw.values[_indexName], isNull);
    expect(raw.values[_keyName], isNull);
  });

  test('archive index does not include plaintext account identity', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    await _prepare(store, oldSnapshot);
    final index = jsonDecode(raw.values[_indexName]!) as Map<String, dynamic>;
    expect(index['version'], 1);
    expect(jsonEncode(index), isNot(contains(_userId)));
    expect(jsonEncode(index), isNot(contains(_homeserver)));
  });

  test('verified original candidate is adopted without copying its secrets',
      () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    final candidateScope = 'b' * 64;
    final candidateKey = base64UrlEncode(List<int>.filled(32, 7));
    raw.values['$_keyName.$candidateScope'] = candidateKey;
    raw.values['$_bindingName.$candidateScope'] =
        jsonEncode(_oldBinding().toJson());
    final candidate = await store.peekMatrixIdentityAtScope(candidateScope);
    final oldValues = Map<String, String>.from(raw.values);

    await store.adoptVerifiedOriginalCandidate(
      expectedHomeserver: _homeserver,
      expectedUserId: _userId,
      expectedSnapshot: oldSnapshot,
      verifiedCandidateSnapshot: candidate,
    );

    expect(raw.values[_activeName], candidateScope);
    expect(raw.values['$_keyName.$candidateScope'], candidateKey);
    expect(raw.values['$_bindingName.$candidateScope'],
        oldValues['$_bindingName.$candidateScope']);
    expect(raw.values[_keyName], oldValues[_keyName]);
    expect(raw.values[_bindingName], oldValues[_bindingName]);
    expect(raw.values[_recoveryName], oldValues[_recoveryName]);
    expect(raw.values[_indexName], contains('"kind":"adopt_original"'));
    expect(raw.values[_journalName], isNull);
  });

  test('adoption registry fault replays to same verified candidate', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    final candidateScope = 'b' * 64;
    raw.values['$_keyName.$candidateScope'] =
        base64UrlEncode(List<int>.filled(32, 7));
    raw.values['$_bindingName.$candidateScope'] =
        jsonEncode(_oldBinding().toJson());
    final candidate = await store.peekMatrixIdentityAtScope(candidateScope);
    raw.failWriteKey = _registryName;

    await expectLater(
        store.adoptVerifiedOriginalCandidate(
          expectedHomeserver: _homeserver,
          expectedUserId: _userId,
          expectedSnapshot: oldSnapshot,
          verifiedCandidateSnapshot: candidate,
        ),
        throwsStateError);
    raw.failWriteKey = null;
    await _replay(SecureSessionStore(raw));

    expect(raw.values[_activeName], candidateScope);
    expect(raw.values[_journalName], isNull);
    expect(raw.values[_keyName], isNotNull);
    expect(raw.values['$_keyName.$candidateScope'], isNotNull);
  });

  test('account B retains its own scope across account A recovery', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    await store.selectMatrixAccount(_homeserver, _userId);
    const otherUser = '@other:matrix.test';
    await store.selectMatrixAccount(_homeserver, otherUser);
    await store.saveMatrixBinding(MatrixLocalBinding(
      version: 2,
      matrixUserId: otherUser,
      deviceId: 'OTHER',
      homeserver: _homeserver,
      databaseGeneration: 'other-generation',
      ed25519Fingerprint: 'other-fingerprint',
    ));
    final otherScope = await store.matrixStorageScope();
    final otherKey = await store.matrixDatabaseKey();
    await store.selectMatrixAccount(_homeserver, _userId);

    final freshScope = await _prepare(store, oldSnapshot);
    await store.selectMatrixAccount(_homeserver, otherUser);
    expect(await store.matrixStorageScope(), otherScope);
    expect(await store.matrixDatabaseKey(), otherKey);
    await store.selectMatrixAccount(_homeserver, _userId);
    expect(await store.matrixStorageScope(), freshScope);
    expect(raw.values[_keyName], oldSnapshot.databaseKey);
  });

  test('changed original key during journal replay fails closed', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.failWriteKey = _indexName;
    await expectLater(_prepare(store, oldSnapshot), throwsStateError);
    raw.failWriteKey = null;
    raw.values[_keyName] = base64UrlEncode(List<int>.filled(32, 9));

    await expectLater(_replay(SecureSessionStore(raw)), throwsStateError);
    expect(raw.values[_activeName], isNull);
    expect(raw.values[_journalName], isNotNull);
    expect(raw.values[_indexName], isNull);
  });

  test('unexpected registry target during replay fails closed', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.failWriteKey = _registryName;
    await expectLater(_prepare(store, oldSnapshot), throwsStateError);
    raw.failWriteKey = null;
    final journal = jsonDecode(raw.values[_journalName]!) as Map;
    final accountHash = (journal['entry'] as Map)['account'] as String;
    raw.values[_registryName] = jsonEncode({accountHash: 'c' * 64});

    await expectLater(_replay(SecureSessionStore(raw)), throwsStateError);
    expect(raw.values[_activeName], isNull);
    expect(raw.values[_journalName], isNotNull);
    expect(raw.values[_indexName], isNotNull);
  });

  test('journal replay requires the authorized account hash', () async {
    final raw = _FaultStore();
    final (store, oldSnapshot) = await _retained(raw);
    raw.failWriteKey = _indexName;
    await expectLater(_prepare(store, oldSnapshot), throwsStateError);
    raw.failWriteKey = null;
    final before = Map<String, String>.from(raw.values);

    await expectLater(
      SecureSessionStore(raw).recoverPendingMatrixArchive(
        expectedHomeserver: _homeserver,
        expectedUserId: '@other:matrix.test',
      ),
      throwsStateError,
    );
    expect(raw.values, before);
    await _replay(SecureSessionStore(raw));
    expect(raw.values[_journalName], isNull);
  });
}
