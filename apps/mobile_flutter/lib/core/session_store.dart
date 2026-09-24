import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:liuhetong_mobile/core/matrix_local_binding.dart';

abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// An inspection read must never migrate a Keychain item as a side effect.
abstract interface class PeekableSecureKeyValueStore {
  Future<String?> peek(String key);
}

final class FlutterSecureKeyValueStore
    implements SecureKeyValueStore, PeekableSecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _iosSession = MethodChannel('chatflow/ios_secure_session');
  bool _nativeSessionKey(String key) =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      (const {
            'liuhetong.matrix_database_key.v1',
            'liuhetong.business_session.v1',
            'liuhetong.active_matrix_scope.v1',
            'liuhetong.matrix_account_slots.v1',
          }.contains(key) ||
          RegExp(r'^liuhetong\.matrix_database_key\.v1\.[a-f0-9]{64}$')
              .hasMatch(key));

  bool _nativePreflightKey(String key) =>
      _nativeSessionKey(key) ||
      (!kIsWeb &&
          defaultTargetPlatform == TargetPlatform.iOS &&
          (const {
                'liuhetong.matrix_local_binding.v1',
                'liuhetong.matrix_clear_tombstone.v1',
                'liuhetong.matrix_archives.v1',
                'liuhetong.matrix_archive_journal.v1',
              }.contains(key) ||
              RegExp(r'^liuhetong\.(matrix_local_binding|matrix_clear_tombstone)\.v1\.[a-f0-9]{64}$')
                  .hasMatch(key)));

  @override
  Future<String?> peek(String key) => _nativePreflightKey(key)
      ? _iosSession.invokeMethod<String>('peek', {'key': key})
      : _storage.read(key: key);

  @override
  Future<void> delete(String key) => _nativeSessionKey(key)
      ? _iosSession.invokeMethod<void>('delete', {'key': key})
      : _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _nativeSessionKey(key)
      ? _iosSession.invokeMethod<String>('read', {'key': key})
      : _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _nativeSessionKey(key)
      ? _iosSession.invokeMethod<void>('write', {'key': key, 'value': value})
      : _storage.write(key: key, value: value);
}

final class MatrixStoredIdentitySnapshot {
  const MatrixStoredIdentitySnapshot({
    required this.scope,
    required this.binding,
    required this.databaseKey,
  });

  final String scope;
  final MatrixLocalBinding? binding;
  final String? databaseKey;
}

/// A pending archive must be replayed explicitly before inspecting a scope.
/// This error deliberately carries no account or key material.
final class MatrixArchiveRecoveryPending implements Exception {
  const MatrixArchiveRecoveryPending();

  @override
  String toString() => 'MatrixArchiveRecoveryPending';
}

final class _MatrixArchiveEntry {
  const _MatrixArchiveEntry({
    required this.kind,
    required this.accountHash,
    required this.archiveId,
    required this.oldScope,
    required this.newScope,
  });

  final String kind;
  final String accountHash;
  final String archiveId;
  final String oldScope;
  final String newScope;

  String get oldDatabaseFile => oldScope.isEmpty
      ? 'liuhetong_matrix.sqlite'
      : 'liuhetong_matrix_$oldScope.sqlite';

  String oldKeyName(String base) => oldScope.isEmpty ? base : '$base.$oldScope';

  Map<String, Object?> toJson() => {
        'kind': kind,
        'account': accountHash,
        'archive_id': archiveId,
        'old_scope': oldScope,
        'new_scope': newScope,
        'database_file': oldDatabaseFile,
        'wal_file': '$oldDatabaseFile-wal',
        'shm_file': '$oldDatabaseFile-shm',
        'database_key_ref': oldKeyName('liuhetong.matrix_database_key.v1'),
        'binding_ref': oldKeyName('liuhetong.matrix_local_binding.v1'),
        'recovery_ref': oldKeyName('liuhetong.encrypted_recovery_key'),
      };

  static _MatrixArchiveEntry parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 11 ||
        !const {'fresh_device', 'adopt_original'}.contains(value['kind']) ||
        value['account'] is! String ||
        value['archive_id'] is! String ||
        value['old_scope'] is! String ||
        value['new_scope'] is! String ||
        value['database_file'] is! String ||
        value['wal_file'] is! String ||
        value['shm_file'] is! String ||
        value['database_key_ref'] is! String ||
        value['binding_ref'] is! String ||
        value['recovery_ref'] is! String) {
      throw const FormatException('Invalid Matrix archive entry');
    }
    final entry = _MatrixArchiveEntry(
      kind: value['kind'] as String,
      accountHash: value['account'] as String,
      archiveId: value['archive_id'] as String,
      oldScope: value['old_scope'] as String,
      newScope: value['new_scope'] as String,
    );
    if (!_AccountScopedSecureStore._hash.hasMatch(entry.accountHash) ||
        !_AccountScopedSecureStore._hash.hasMatch(entry.archiveId) ||
        (entry.oldScope.isNotEmpty &&
            !_AccountScopedSecureStore._hash.hasMatch(entry.oldScope)) ||
        (entry.newScope.isEmpty
            ? entry.kind != 'adopt_original'
            : !_AccountScopedSecureStore._hash.hasMatch(entry.newScope)) ||
        value['database_file'] != entry.oldDatabaseFile ||
        value['wal_file'] != '${entry.oldDatabaseFile}-wal' ||
        value['shm_file'] != '${entry.oldDatabaseFile}-shm' ||
        value['database_key_ref'] !=
            entry.oldKeyName('liuhetong.matrix_database_key.v1') ||
        value['binding_ref'] !=
            entry.oldKeyName('liuhetong.matrix_local_binding.v1') ||
        value['recovery_ref'] !=
            entry.oldKeyName('liuhetong.encrypted_recovery_key') ||
        entry.oldScope == entry.newScope) {
      throw const FormatException('Invalid Matrix archive entry');
    }
    return entry;
  }

  @override
  bool operator ==(Object other) =>
      other is _MatrixArchiveEntry &&
      other.kind == kind &&
      other.accountHash == accountHash &&
      other.archiveId == archiveId &&
      other.oldScope == oldScope &&
      other.newScope == newScope;

  @override
  int get hashCode =>
      Object.hash(kind, accountHash, archiveId, oldScope, newScope);
}

final class _MatrixArchiveJournal {
  const _MatrixArchiveJournal({
    required this.entry,
    required this.priorActiveScope,
    required this.oldKeyDigest,
    required this.oldBindingDigest,
    required this.newKeyDigest,
    required this.newBindingDigest,
    required this.phase,
  });

  final _MatrixArchiveEntry entry;
  final String priorActiveScope;
  final String oldKeyDigest;
  final String oldBindingDigest;
  final String? newKeyDigest;
  final String? newBindingDigest;
  final String phase;

  _MatrixArchiveJournal committed() => _MatrixArchiveJournal(
        entry: entry,
        priorActiveScope: priorActiveScope,
        oldKeyDigest: oldKeyDigest,
        oldBindingDigest: oldBindingDigest,
        newKeyDigest: newKeyDigest,
        newBindingDigest: newBindingDigest,
        phase: 'committed',
      );

  Map<String, Object?> toJson() => {
        'version': 1,
        'kind': entry.kind,
        'entry': entry.toJson(),
        'prior_active_scope': priorActiveScope,
        'old_key_digest': oldKeyDigest,
        'old_binding_digest': oldBindingDigest,
        'new_key_digest': newKeyDigest,
        'new_binding_digest': newBindingDigest,
        'phase': phase,
      };

  static _MatrixArchiveJournal parse(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic> ||
        value.length != 9 ||
        value['version'] != 1 ||
        !const {'fresh_device', 'adopt_original'}.contains(value['kind']) ||
        value['entry'] is! Map<String, dynamic> ||
        value['prior_active_scope'] is! String ||
        value['old_key_digest'] is! String ||
        value['old_binding_digest'] is! String ||
        !const {'prepared', 'committed'}.contains(value['phase'])) {
      throw const FormatException('Invalid Matrix archive journal');
    }
    final priorActive = value['prior_active_scope'] as String;
    final oldKeyDigest = value['old_key_digest'] as String;
    final oldBindingDigest = value['old_binding_digest'] as String;
    if ((priorActive.isNotEmpty &&
            !_AccountScopedSecureStore._hash.hasMatch(priorActive)) ||
        !_AccountScopedSecureStore._hash.hasMatch(oldKeyDigest) ||
        !_AccountScopedSecureStore._hash.hasMatch(oldBindingDigest)) {
      throw const FormatException('Invalid Matrix archive journal');
    }
    final entry = _MatrixArchiveEntry.parse(value['entry']);
    final newKeyDigest = value['new_key_digest'];
    final newBindingDigest = value['new_binding_digest'];
    if (entry.kind != value['kind'] ||
        (entry.kind == 'fresh_device' &&
            (newKeyDigest != null || newBindingDigest != null)) ||
        (entry.kind == 'adopt_original' &&
            (newKeyDigest is! String ||
                newBindingDigest is! String ||
                !_AccountScopedSecureStore._hash.hasMatch(newKeyDigest) ||
                !_AccountScopedSecureStore._hash.hasMatch(newBindingDigest)))) {
      throw const FormatException('Invalid Matrix archive journal');
    }
    return _MatrixArchiveJournal(
      entry: entry,
      priorActiveScope: priorActive,
      oldKeyDigest: oldKeyDigest,
      oldBindingDigest: oldBindingDigest,
      newKeyDigest: newKeyDigest as String?,
      newBindingDigest: newBindingDigest as String?,
      phase: value['phase'] as String,
    );
  }
}

final class StoredBusinessSession {
  const StoredBusinessSession({
    required this.version,
    required this.accessToken,
    required this.refreshToken,
    this.matrixUserId,
    this.deviceKey,
    this.pendingRefreshOperation,
  });

  final int version;
  final String accessToken;
  final String refreshToken;
  final String? matrixUserId;
  final String? deviceKey;
  final String? pendingRefreshOperation;

  @override
  bool operator ==(Object other) =>
      other is StoredBusinessSession &&
      other.version == version &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.matrixUserId == matrixUserId &&
      other.deviceKey == deviceKey &&
      other.pendingRefreshOperation == pendingRefreshOperation;

  @override
  int get hashCode => Object.hash(version, accessToken, refreshToken,
      matrixUserId, deviceKey, pendingRefreshOperation);
}

final class SecureSessionStore {
  SecureSessionStore([SecureKeyValueStore? storage])
      : _storage =
            _AccountScopedSecureStore(storage ?? FlutterSecureKeyValueStore());

  final _AccountScopedSecureStore _storage;
  Future<void> _matrixIdentityOperations = Future<void>.value();

  static const _sessionKey = 'liuhetong.business_session.v1';
  static const _legacyAccessKey = 'liuhetong.access_token';
  static const _legacyRefreshKey = 'liuhetong.refresh_token';
  static const _recoveryKey = 'liuhetong.encrypted_recovery_key';
  static const _matrixDatabaseKey = 'liuhetong.matrix_database_key.v1';
  static const _matrixBindingKey = 'liuhetong.matrix_local_binding.v1';
  static const _diagnosticSaltKey = 'liuhetong.diagnostic_salt.v1';
  static const _registrationDeviceKey = 'liuhetong.registration_device_key.v1';
  static const _matrixClearTombstoneKey = 'liuhetong.matrix_clear_tombstone.v1';
  static const _matrixClearTombstoneValue = '{"version":1,"pending":true}';
  static const _matrixArchiveIndexKey = 'liuhetong.matrix_archives.v1';
  static const _matrixArchiveJournalKey = 'liuhetong.matrix_archive_journal.v1';

  /// 按槽隔离的键名。清空一次安装时要连同它们的全部槽后缀一起删除。
  static const _scopedKeyNames = <String>[
    _matrixDatabaseKey,
    _matrixBindingKey,
    _recoveryKey,
    _diagnosticSaltKey,
    _matrixClearTombstoneKey,
  ];

  /// 独立于槽的固定键。ADR-0063 之前的单账号遗留键用空后缀覆盖。
  static const _slotIndependentKeys = <String>[
    _AccountScopedSecureStore.activeKey,
    _AccountScopedSecureStore.registryKey,
    _sessionKey,
    _registrationDeviceKey,
    _legacyAccessKey,
    _legacyRefreshKey,
  ];

  static final _hashToken = RegExp(r'[a-f0-9]{64}');

  Future<String> matrixStorageScope() =>
      _runMatrixIdentityOperation(_storage.scope);

  /// Read-only Keychain snapshot for inspection before Matrix SDK init.
  Future<MatrixStoredIdentitySnapshot> peekActiveMatrixIdentity() =>
      _runMatrixIdentityOperation(
          () async => _peekIdentityAtScopeUnlocked(await _storage.peekScope()));

  /// Resolves the target account without writing registry or active scope.
  Future<MatrixStoredIdentitySnapshot> peekAccountMatrixIdentity(
          String homeserver, String userId) =>
      _runMatrixIdentityOperation(() async {
        if (Uri.tryParse(homeserver)?.hasAuthority != true ||
            !userId.startsWith('@') ||
            !userId.contains(':')) {
          throw const FormatException('Invalid Matrix account identity');
        }
        final slots = await _storage.peekSlots();
        final current = await _storage.peekScope();
        final old = (await _peekIdentityAtScopeUnlocked(current)).binding;
        if (old != null) {
          final identity = _AccountScopedSecureStore.identity(
              old.homeserver, old.matrixUserId);
          if (slots.containsKey(identity) && slots[identity] != current) {
            throw const FormatException('Conflicting Matrix account registry');
          }
          slots[identity] = current;
        }
        final target = _AccountScopedSecureStore.identity(homeserver, userId);
        return _peekIdentityAtScopeUnlocked(slots[target] ?? target);
      });

  /// Scope candidates from the registry and the legacy unsuffixed store.
  Future<Set<String>> peekKnownMatrixScopes() =>
      _runMatrixIdentityOperation(() async {
        final slots = await _storage.peekSlots();
        final active = await _storage.peekScope();
        return <String>{'', active, ...slots.values};
      });

  Future<bool> peekMatrixClearPending() =>
      _runMatrixIdentityOperation(() async {
        final scope = await _storage.peekScope();
        final key = scope.isEmpty
            ? _matrixClearTombstoneKey
            : '$_matrixClearTombstoneKey.$scope';
        final value = await _storage.peekRaw(key);
        if (value == null) return false;
        if (value != _matrixClearTombstoneValue) {
          throw const FormatException('Invalid Matrix clear tombstone');
        }
        return true;
      });

  Future<MatrixStoredIdentitySnapshot> peekMatrixIdentityAtScope(
          String scope) =>
      _runMatrixIdentityOperation(() => _peekIdentityAtScopeUnlocked(scope));

  Future<MatrixStoredIdentitySnapshot> _peekIdentityAtScopeUnlocked(
      String scope) async {
    if (scope.isNotEmpty && !_AccountScopedSecureStore._hash.hasMatch(scope)) {
      throw const FormatException('Invalid Matrix storage scope');
    }
    final bindingKey =
        scope.isEmpty ? _matrixBindingKey : '$_matrixBindingKey.$scope';
    final databaseKey =
        scope.isEmpty ? _matrixDatabaseKey : '$_matrixDatabaseKey.$scope';
    final encoded = await _storage.peekRaw(bindingKey);
    final binding = encoded == null ? null : _decodeMatrixBinding(encoded);
    return MatrixStoredIdentitySnapshot(
      scope: scope,
      binding: binding,
      databaseKey: await _storage.peekRaw(databaseKey),
    );
  }

  static MatrixLocalBinding _decodeMatrixBinding(String encoded) {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid matrix local binding');
    }
    return MatrixLocalBinding.fromJson(value);
  }

  /// Replays a durable archive transaction before any scope decision or SDK
  /// initialization. Inspection APIs deliberately never call this method.
  Future<void> recoverPendingMatrixArchive({
    required String expectedHomeserver,
    required String expectedUserId,
  }) =>
      _runMatrixIdentityOperation(() async {
        final encoded = await _storage.peekRaw(_matrixArchiveJournalKey);
        if (encoded == null) return;
        final journal = _MatrixArchiveJournal.parse(encoded);
        if (_AccountScopedSecureStore.identity(
                expectedHomeserver, expectedUserId) !=
            journal.entry.accountHash) {
          throw StateError('Matrix archive target is not authorized');
        }
        await _completeMatrixArchiveUnlocked(journal);
      }, skipArchiveRecovery: true);

  Future<String?> confirmedFreshDeviceScope(String homeserver, String userId) =>
      _runMatrixIdentityOperation(
          () => _confirmedFreshDeviceScopeUnlocked(homeserver, userId));

  Future<bool> peekUnboundFreshDeviceAwaitingAuth() =>
      _runMatrixIdentityOperation(() async {
        final scope = await _storage.peekScope();
        final snapshot = await _peekIdentityAtScopeUnlocked(scope);
        if (snapshot.binding != null || snapshot.databaseKey == null) {
          return false;
        }
        final slots = await _storage.peekSlots();
        final archives = await _archiveEntriesUnlocked();
        return archives.any((entry) =>
            entry.kind == 'fresh_device' &&
            entry.newScope == scope &&
            slots[entry.accountHash] == scope);
      });

  Future<String?> _confirmedFreshDeviceScopeUnlocked(
      String homeserver, String userId) async {
    final target = _AccountScopedSecureStore.identity(homeserver, userId);
    final slots = await _storage.peekSlots();
    final current = await _storage.peekScope();
    if (slots[target] != current || current.isEmpty) return null;
    final snapshot = await _peekIdentityAtScopeUnlocked(current);
    if (snapshot.binding != null || snapshot.databaseKey == null) return null;
    final entries = await _archiveEntriesUnlocked();
    return entries.any((entry) =>
            entry.kind == 'fresh_device' &&
            entry.accountHash == target &&
            entry.newScope == current)
        ? current
        : null;
  }

  /// The caller has already stopped the old client and independently proved
  /// that no complete original Olm identity exists in any local candidate.
  /// A random, empty slot is committed only after its old scope is durable in
  /// the archive index. The callback rejects main DBs and every sidecar.
  Future<String> prepareFreshDeviceForConfirmedRecovery({
    required String expectedHomeserver,
    required String expectedUserId,
    required MatrixStoredIdentitySnapshot expectedSnapshot,
    required Future<bool> Function(String scope) scopeHasDatabaseFiles,
  }) =>
      _runMatrixIdentityOperation(() async {
        if (Uri.tryParse(expectedHomeserver)?.hasAuthority != true ||
            !expectedUserId.startsWith('@') ||
            !expectedUserId.contains(':')) {
          throw const FormatException('Invalid Matrix account identity');
        }
        final already = await _confirmedFreshDeviceScopeUnlocked(
            expectedHomeserver, expectedUserId);
        if (already != null) return already;

        final slots = await _storage.slots();
        final priorActive = await _storage.scope();
        final activeBinding =
            (await _peekIdentityAtScopeUnlocked(priorActive)).binding;
        if (activeBinding != null) {
          final activeAccount = _AccountScopedSecureStore.identity(
              activeBinding.homeserver, activeBinding.matrixUserId);
          if (slots.containsKey(activeAccount) &&
              slots[activeAccount] != priorActive) {
            throw const FormatException('Conflicting Matrix account registry');
          }
          slots[activeAccount] = priorActive;
        }
        final target = _AccountScopedSecureStore.identity(
            expectedHomeserver, expectedUserId);
        final oldScope = slots[target] ?? target;
        final actual = await _peekIdentityAtScopeUnlocked(oldScope);
        final oldBinding = actual.binding;
        final oldKey = actual.databaseKey;
        if (actual.scope != expectedSnapshot.scope ||
            oldBinding != expectedSnapshot.binding ||
            oldKey != expectedSnapshot.databaseKey ||
            oldBinding == null ||
            oldKey == null ||
            oldKey.isEmpty ||
            oldBinding.homeserver != expectedHomeserver ||
            oldBinding.matrixUserId != expectedUserId) {
          throw StateError('Matrix account changed during confirmed recovery');
        }
        final entries = await _archiveEntriesUnlocked();
        final occupied = <String>{
          oldScope,
          priorActive,
          ...slots.values,
          for (final entry in entries) ...[entry.oldScope, entry.newScope],
        };
        String? newScope;
        for (var attempt = 0; attempt < 32; attempt++) {
          final candidate =
              List<int>.generate(32, (_) => Random.secure().nextInt(256));
          final scope = candidate
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join();
          if (occupied.contains(scope) || await scopeHasDatabaseFiles(scope)) {
            continue;
          }
          var occupiedKey = false;
          for (final name in _scopedKeyNames) {
            if (await _storage.peekRaw('$name.$scope') != null) {
              occupiedKey = true;
              break;
            }
          }
          if (!occupiedKey) {
            newScope = scope;
            break;
          }
        }
        if (newScope == null) {
          throw StateError('No empty Matrix archive scope');
        }
        final archiveId = sha256
            .convert(utf8.encode(jsonEncode([
              'fresh_device',
              expectedHomeserver,
              expectedUserId,
              oldBinding.databaseGeneration,
              oldScope,
            ])))
            .toString();
        final journal = _MatrixArchiveJournal(
          entry: _MatrixArchiveEntry(
            kind: 'fresh_device',
            accountHash: target,
            archiveId: archiveId,
            oldScope: oldScope,
            newScope: newScope,
          ),
          priorActiveScope: priorActive,
          oldKeyDigest: sha256.convert(utf8.encode(oldKey)).toString(),
          oldBindingDigest: sha256
              .convert(utf8.encode(jsonEncode(oldBinding.toJson())))
              .toString(),
          newKeyDigest: null,
          newBindingDigest: null,
          phase: 'prepared',
        );
        await _storage.raw
            .write(_matrixArchiveJournalKey, jsonEncode(journal.toJson()));
        final checked = await _storage.peekRaw(_matrixArchiveJournalKey);
        if (checked == null ||
            jsonEncode(_MatrixArchiveJournal.parse(checked).toJson()) !=
                jsonEncode(journal.toJson())) {
          throw StateError('Matrix archive journal verification failed');
        }
        await _completeMatrixArchiveUnlocked(journal);
        return newScope;
      });

  /// Switches to a separately verified copy of the original Olm identity.
  /// The factory must prove the candidate DB and fingerprint before calling.
  /// This transaction changes pointers only; neither slot's key or DB is
  /// created, copied, deleted or rewritten.
  Future<void> adoptVerifiedOriginalCandidate({
    required String expectedHomeserver,
    required String expectedUserId,
    required MatrixStoredIdentitySnapshot expectedSnapshot,
    required MatrixStoredIdentitySnapshot verifiedCandidateSnapshot,
  }) =>
      _runMatrixIdentityOperation(() async {
        if (Uri.tryParse(expectedHomeserver)?.hasAuthority != true ||
            !expectedUserId.startsWith('@') ||
            !expectedUserId.contains(':')) {
          throw const FormatException('Invalid Matrix account identity');
        }
        final slots = await _storage.slots();
        final priorActive = await _storage.scope();
        final activeBinding =
            (await _peekIdentityAtScopeUnlocked(priorActive)).binding;
        if (activeBinding != null) {
          final activeAccount = _AccountScopedSecureStore.identity(
              activeBinding.homeserver, activeBinding.matrixUserId);
          if (slots.containsKey(activeAccount) &&
              slots[activeAccount] != priorActive) {
            throw const FormatException('Conflicting Matrix account registry');
          }
          slots[activeAccount] = priorActive;
        }
        final target = _AccountScopedSecureStore.identity(
            expectedHomeserver, expectedUserId);
        final oldScope = slots[target] ?? target;
        final old = await _peekIdentityAtScopeUnlocked(oldScope);
        final candidate =
            await _peekIdentityAtScopeUnlocked(verifiedCandidateSnapshot.scope);
        if (old.scope != expectedSnapshot.scope ||
            old.binding != expectedSnapshot.binding ||
            old.databaseKey != expectedSnapshot.databaseKey ||
            candidate.scope != verifiedCandidateSnapshot.scope ||
            candidate.binding != verifiedCandidateSnapshot.binding ||
            candidate.databaseKey != verifiedCandidateSnapshot.databaseKey ||
            candidate.scope == old.scope ||
            old.binding == null ||
            old.databaseKey == null ||
            candidate.binding == null ||
            candidate.databaseKey == null ||
            candidate.binding!.homeserver != expectedHomeserver ||
            candidate.binding!.matrixUserId != expectedUserId ||
            old.binding!.homeserver != expectedHomeserver ||
            old.binding!.matrixUserId != expectedUserId ||
            old.binding!.ed25519Fingerprint == null ||
            old.binding!.ed25519Fingerprint !=
                candidate.binding!.ed25519Fingerprint ||
            slots.entries.any((entry) =>
                entry.key != target && entry.value == candidate.scope)) {
          throw StateError('Verified Matrix original candidate changed');
        }
        final oldBinding = old.binding!;
        final candidateBinding = candidate.binding!;
        final oldKey = old.databaseKey!;
        final candidateKey = candidate.databaseKey!;
        final archiveId = sha256
            .convert(utf8.encode(jsonEncode([
              'adopt_original',
              expectedHomeserver,
              expectedUserId,
              oldBinding.databaseGeneration,
              oldScope,
              candidate.scope,
            ])))
            .toString();
        final journal = _MatrixArchiveJournal(
          entry: _MatrixArchiveEntry(
            kind: 'adopt_original',
            accountHash: target,
            archiveId: archiveId,
            oldScope: oldScope,
            newScope: candidate.scope,
          ),
          priorActiveScope: priorActive,
          oldKeyDigest: sha256.convert(utf8.encode(oldKey)).toString(),
          oldBindingDigest: sha256
              .convert(utf8.encode(jsonEncode(oldBinding.toJson())))
              .toString(),
          newKeyDigest: sha256.convert(utf8.encode(candidateKey)).toString(),
          newBindingDigest: sha256
              .convert(utf8.encode(jsonEncode(candidateBinding.toJson())))
              .toString(),
          phase: 'prepared',
        );
        await _storage.raw
            .write(_matrixArchiveJournalKey, jsonEncode(journal.toJson()));
        final checked = await _storage.peekRaw(_matrixArchiveJournalKey);
        if (checked == null ||
            jsonEncode(_MatrixArchiveJournal.parse(checked).toJson()) !=
                jsonEncode(journal.toJson())) {
          throw StateError('Matrix archive journal verification failed');
        }
        await _completeMatrixArchiveUnlocked(journal);
      });

  Future<List<_MatrixArchiveEntry>> _archiveEntriesUnlocked() async {
    final encoded = await _storage.peekRaw(_matrixArchiveIndexKey);
    if (encoded == null) return <_MatrixArchiveEntry>[];
    final parsed = jsonDecode(encoded);
    if (parsed is! Map<String, dynamic> ||
        parsed.length != 2 ||
        parsed['version'] != 1 ||
        parsed['entries'] is! List) {
      throw const FormatException('Invalid Matrix archive index');
    }
    final rawEntries = parsed['entries'] as List;
    if (rawEntries.length > 256) {
      throw const FormatException('Invalid Matrix archive index');
    }
    final entries = rawEntries.map(_MatrixArchiveEntry.parse).toList();
    if (entries.toSet().length != entries.length ||
        entries.map((entry) => entry.newScope).toSet().length !=
            entries.length) {
      throw const FormatException('Invalid Matrix archive index');
    }
    return entries;
  }

  Future<void> _completeMatrixArchiveUnlocked(
      _MatrixArchiveJournal journal) async {
    final entry = journal.entry;
    final old = await _peekIdentityAtScopeUnlocked(entry.oldScope);
    if (old.binding == null ||
        old.databaseKey == null ||
        sha256.convert(utf8.encode(old.databaseKey!)).toString() !=
            journal.oldKeyDigest ||
        sha256
                .convert(utf8.encode(jsonEncode(old.binding!.toJson())))
                .toString() !=
            journal.oldBindingDigest ||
        _AccountScopedSecureStore.identity(
                old.binding!.homeserver, old.binding!.matrixUserId) !=
            entry.accountHash) {
      throw StateError('Retained Matrix archive identity changed');
    }

    final slots = await _storage.slots();
    final oldTarget = slots[entry.accountHash];
    final rawActive =
        await _storage.peekRaw(_AccountScopedSecureStore.activeKey);
    if (oldTarget != null &&
        oldTarget != entry.oldScope &&
        oldTarget != entry.newScope) {
      throw StateError('Conflicting Matrix archive registry');
    }
    if (slots.entries.any((slot) =>
        slot.key != entry.accountHash && slot.value == entry.newScope)) {
      throw StateError('Conflicting Matrix archive registry');
    }
    if (rawActive != journal.priorActiveScope &&
        rawActive != entry.newScope &&
        !(rawActive == null && journal.priorActiveScope.isEmpty)) {
      throw StateError('Conflicting Matrix archive active scope');
    }
    if (journal.phase == 'committed' &&
        (oldTarget != entry.newScope || rawActive != entry.newScope)) {
      throw StateError('Invalid committed Matrix archive');
    }

    final archives = await _archiveEntriesUnlocked();
    final related = archives.where((saved) =>
        saved.archiveId == entry.archiveId || saved.newScope == entry.newScope);
    if (related.any((saved) => saved != entry)) {
      throw StateError('Conflicting Matrix archive index');
    }
    if (!archives.contains(entry)) {
      final updated = [...archives, entry];
      await _storage.raw.write(
          _matrixArchiveIndexKey,
          jsonEncode({
            'version': 1,
            'entries': updated.map((e) => e.toJson()).toList()
          }));
    }
    final verifiedArchives = await _archiveEntriesUnlocked();
    if (!verifiedArchives.contains(entry)) {
      throw StateError('Matrix archive index verification failed');
    }

    if (entry.kind == 'fresh_device') {
      final newKeyName = '$_matrixDatabaseKey.${entry.newScope}';
      var newKey = await _storage.peekRaw(newKeyName);
      if (newKey == null) {
        final random = Random.secure();
        newKey =
            base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
        await _storage.raw.write(newKeyName, newKey);
      }
      if (newKey == old.databaseKey ||
          !_validMatrixDatabaseKey(newKey) ||
          await _storage.peekRaw(newKeyName) != newKey) {
        throw StateError('Matrix fresh scope key verification failed');
      }
    } else {
      final candidate = await _peekIdentityAtScopeUnlocked(entry.newScope);
      final candidateBinding = candidate.binding;
      final candidateKey = candidate.databaseKey;
      if (candidateBinding == null ||
          candidateKey == null ||
          sha256.convert(utf8.encode(candidateKey)).toString() !=
              journal.newKeyDigest ||
          sha256
                  .convert(utf8.encode(jsonEncode(candidateBinding.toJson())))
                  .toString() !=
              journal.newBindingDigest ||
          _AccountScopedSecureStore.identity(
                  candidateBinding.homeserver, candidateBinding.matrixUserId) !=
              entry.accountHash ||
          candidateBinding.ed25519Fingerprint == null ||
          candidateBinding.ed25519Fingerprint !=
              old.binding!.ed25519Fingerprint) {
        throw StateError('Verified Matrix original candidate changed');
      }
    }

    if (oldTarget != entry.newScope) {
      slots[entry.accountHash] = entry.newScope;
      await _storage.raw
          .write(_AccountScopedSecureStore.registryKey, jsonEncode(slots));
    }
    final verifiedSlots = await _storage.peekSlots();
    if (verifiedSlots[entry.accountHash] != entry.newScope) {
      throw StateError('Matrix archive registry verification failed');
    }
    if (rawActive != entry.newScope) {
      await _storage.raw
          .write(_AccountScopedSecureStore.activeKey, entry.newScope);
    }
    if (await _storage.peekRaw(_AccountScopedSecureStore.activeKey) !=
        entry.newScope) {
      throw StateError('Matrix archive active scope verification failed');
    }
    if (journal.phase != 'committed') {
      final committed = journal.committed();
      await _storage.raw
          .write(_matrixArchiveJournalKey, jsonEncode(committed.toJson()));
      final checked = await _storage.peekRaw(_matrixArchiveJournalKey);
      if (checked == null ||
          jsonEncode(_MatrixArchiveJournal.parse(checked).toJson()) !=
              jsonEncode(committed.toJson())) {
        throw StateError('Matrix archive commit verification failed');
      }
    }
    await _storage.raw.delete(_matrixArchiveJournalKey);
    if (await _storage.peekRaw(_matrixArchiveJournalKey) != null) {
      throw StateError('Matrix archive journal removal failed');
    }
  }

  static bool _validMatrixDatabaseKey(String value) {
    try {
      return base64Url.decode(base64Url.normalize(value)).length == 32;
    } catch (_) {
      return false;
    }
  }

  /// Read-only preflight before a password login can replace a remote session.
  /// This checks the active local metadata, not an unauthenticated target user.
  Future<void> validateLocalLoginStorage() =>
      _runMatrixIdentityOperation(() async {
        final slots = await _storage.slots();
        final scope = await _storage.scope();
        final binding = await _matrixBindingUnlocked();
        final key = await _storage.read(_matrixDatabaseKey);
        if (binding != null) {
          final identity = _AccountScopedSecureStore.identity(
              binding.homeserver, binding.matrixUserId);
          if (slots.containsKey(identity) && slots[identity] != scope) {
            throw const FormatException('Conflicting Matrix account registry');
          }
          if (key == null || key.isEmpty) {
            throw const FormatException('Missing retained Matrix database key');
          }
        }
        // Decode the existing clear marker without carrying out a pending deletion.
        final pending = await _storage.read(_matrixClearTombstoneKey);
        if (pending != null && pending != _matrixClearTombstoneValue) {
          throw const FormatException('Invalid Matrix clear tombstone');
        }
      });

  /// Only called after business authentication and the old client has closed.
  Future<void> selectMatrixAccount(String homeserver, String userId,
          {MatrixStoredIdentitySnapshot? expectedSnapshot}) =>
      _runMatrixIdentityOperation(() async {
        if (Uri.tryParse(homeserver)?.hasAuthority != true ||
            !userId.startsWith('@') ||
            !userId.contains(':')) {
          throw const FormatException('Invalid Matrix account identity');
        }
        final slots = await _storage.slots();
        final current = await _storage.scope();
        final old = await _matrixBindingUnlocked();
        if (old != null) {
          final identity = _AccountScopedSecureStore.identity(
              old.homeserver, old.matrixUserId);
          if (slots.containsKey(identity) && slots[identity] != current) {
            throw const FormatException('Conflicting Matrix account registry');
          }
          slots[identity] = current;
        }
        final target = _AccountScopedSecureStore.identity(homeserver, userId);
        // An unclaimed legacy store stays untouched. New identities use new slots.
        final selected = slots[target] ?? target;
        if (expectedSnapshot != null) {
          final currentTarget = await _peekIdentityAtScopeUnlocked(selected);
          if (selected != expectedSnapshot.scope ||
              currentTarget.binding != expectedSnapshot.binding ||
              currentTarget.databaseKey != expectedSnapshot.databaseKey) {
            throw StateError('Matrix account changed during local preflight');
          }
        }
        slots[target] = selected;
        await _storage.raw
            .write(_AccountScopedSecureStore.registryKey, jsonEncode(slots));
        await _storage.raw.write(_AccountScopedSecureStore.activeKey, selected);
      });

  Future<void> markMatrixClearPending() => _runMatrixIdentityOperation(
        () => _storage.write(
          _matrixClearTombstoneKey,
          _matrixClearTombstoneValue,
        ),
      );

  Future<bool> matrixClearPending() => _runMatrixIdentityOperation(() async {
        final value = await _storage.read(_matrixClearTombstoneKey);
        if (value == null) return false;
        if (value != _matrixClearTombstoneValue) {
          throw const FormatException('Invalid Matrix clear tombstone');
        }
        return true;
      });

  Future<void> clearMatrixClearPending() => _runMatrixIdentityOperation(
        () => _storage.delete(_matrixClearTombstoneKey),
      );

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    String? matrixUserId,
    String? deviceKey,
    String? pendingRefreshOperation,
  }) =>
      _storage.write(
        _sessionKey,
        jsonEncode({
          'version': 1,
          'access_token': accessToken,
          'refresh_token': refreshToken,
          if (matrixUserId != null) 'matrix_user_id': matrixUserId,
          if (deviceKey != null) 'device_key': deviceKey,
          if (pendingRefreshOperation != null)
            'pending_refresh_operation': pendingRefreshOperation,
        }),
      );

  Future<StoredBusinessSession?> session() async {
    final encoded = await _storage.read(_sessionKey);
    if (encoded != null) {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['access_token'] is! String ||
          value['refresh_token'] is! String ||
          (value['pending_refresh_operation'] != null &&
              !_validRefreshOperation(value['pending_refresh_operation']))) {
        throw const FormatException('Invalid stored business session');
      }
      return StoredBusinessSession(
        version: 1,
        accessToken: value['access_token'] as String,
        refreshToken: value['refresh_token'] as String,
        matrixUserId: value['matrix_user_id']?.toString(),
        deviceKey: value['device_key']?.toString(),
        pendingRefreshOperation: value['pending_refresh_operation'] as String?,
      );
    }
    return _migrateLegacySession();
  }

  static String newRefreshOperation() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static bool _validRefreshOperation(Object? value) {
    if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
      return false;
    }
    final decoded = base64Url.decode('$value=');
    return decoded.length == 32 &&
        base64UrlEncode(decoded).replaceAll('=', '') == value;
  }

  Future<StoredBusinessSession?> _migrateLegacySession() async {
    final access = await _storage.read(_legacyAccessKey);
    final refresh = await _storage.read(_legacyRefreshKey);
    if (access == null && refresh == null) return null;
    if (access == null || refresh == null) {
      await _storage.delete(_legacyAccessKey);
      await _storage.delete(_legacyRefreshKey);
      return null;
    }
    await saveSession(accessToken: access, refreshToken: refresh);
    await _storage.delete(_legacyAccessKey);
    await _storage.delete(_legacyRefreshKey);
    return StoredBusinessSession(
      version: 1,
      accessToken: access,
      refreshToken: refresh,
      matrixUserId: null,
      deviceKey: null,
    );
  }

  Future<String?> accessToken() async => (await session())?.accessToken;
  Future<String?> refreshToken() async => (await session())?.refreshToken;

  Future<void> clearBusinessSession() => _storage.delete(_sessionKey);

  Future<T> _runMatrixIdentityOperation<T>(Future<T> Function() operation,
      {bool skipArchiveRecovery = false}) {
    final result = _matrixIdentityOperations.then<T>((_) async {
      if (!skipArchiveRecovery &&
          await _storage.peekRaw(_matrixArchiveJournalKey) != null) {
        throw const MatrixArchiveRecoveryPending();
      }
      return operation();
    });
    _matrixIdentityOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> saveMatrixBinding(MatrixLocalBinding binding) =>
      _runMatrixIdentityOperation(() => _saveMatrixBindingUnlocked(binding));

  Future<void> _saveMatrixBindingUnlocked(MatrixLocalBinding binding) =>
      _storage.write(_matrixBindingKey, jsonEncode(binding.toJson()));

  /// Removes the current scope's continuity binding. Only for the stale-
  /// binding case in continuityMetadata: the scoped encrypted store no longer
  /// exists (out-of-band destruction such as an iOS reinstall), so the
  /// surviving binding describes nothing and must not block future logins.
  Future<void> clearMatrixBinding() =>
      _runMatrixIdentityOperation(_clearMatrixBindingUnlocked);

  Future<void> _clearMatrixBindingUnlocked() =>
      _storage.delete(_matrixBindingKey);

  /// 服务端权威 device id 轮换后的原子迁移。
  ///
  /// 单设备登录策略会让服务端把本机保留的 device-OLD 换成 device-NEW。token 登录
  /// 已经证明账号归属，此时本地 binding 必须跟着走，否则后续每一次 continuity
  /// 校验都会把"可恢复的轮换"误判成身份损坏（L04），并让账号切换流程也永久
  /// 卡在 account_storage（L07）。
  ///
  /// 只允许改写 `deviceId`。以下字段必须与 binding 完全一致，否则拒绝迁移并保留
  /// 原 binding（失败关闭）：
  /// `matrixUserId`、`homeserver`、`ed25519Fingerprint`（binding 已记录时）。
  /// `databaseGeneration` 与 binding 自身保持原值——它不是从调用方传入的事实，
  /// 而是这次绑定所属本地库的代号，随 device id 一起被继承。
  ///
  /// 整个读改写过程在 `_runMatrixIdentityOperation` 串行区内完成，因此与其它
  /// scope/binding 操作原子互斥。返回迁移后的 binding；没有 binding 时返回 null
  /// （此时由 continuityMetadata 建立首次绑定，无需迁移）。
  Future<MatrixLocalBinding?> rotateMatrixDeviceBinding({
    required String expectedUserId,
    required String expectedHomeserver,
    required String previousDeviceId,
    required String nextDeviceId,
    required String? ed25519Fingerprint,
  }) =>
      _runMatrixIdentityOperation(() async {
        final binding = await _matrixBindingUnlocked();
        if (binding == null) return null;
        if (binding.deviceId != previousDeviceId) {
          throw const MatrixDeviceBindingRotationRejected('device-changed');
        }
        return _rewriteBindingDeviceId(
          binding,
          expectedUserId: expectedUserId,
          expectedHomeserver: expectedHomeserver,
          nextDeviceId: nextDeviceId,
          ed25519Fingerprint: ed25519Fingerprint,
        );
      });

  /// 重新打开本地库时补齐 device id。
  ///
  /// 与 [rotateMatrixDeviceBinding] 的区别只在于调用方无法提供"轮换前的 device id"
  /// （那次轮换可能发生在上一进程、且进程在写入 binding 之前被杀）。因此这里不比较
  /// `binding.deviceId`，而把判定完全落在真正的密码学锚点上：Matrix 用户、homeserver
  /// 与 Ed25519 fingerprint 必须逐字相同，且新 device id 非空、与原值不同。
  /// 只差 device id 的 binding 描述的是同一个本地密码学身份，服务端随时可以轮换
  /// 这个标签，因此补齐它不弱化任何身份校验；任何 fingerprint/generation/user/
  /// homeserver 的不一致仍然失败关闭。
  Future<MatrixLocalBinding?> adoptMatrixDeviceId({
    required String expectedUserId,
    required String expectedHomeserver,
    required String nextDeviceId,
    required String? ed25519Fingerprint,
  }) =>
      _runMatrixIdentityOperation(() async {
        final binding = await _matrixBindingUnlocked();
        if (binding == null) return null;
        return _rewriteBindingDeviceId(
          binding,
          expectedUserId: expectedUserId,
          expectedHomeserver: expectedHomeserver,
          nextDeviceId: nextDeviceId,
          ed25519Fingerprint: ed25519Fingerprint,
        );
      });

  Future<MatrixLocalBinding> _rewriteBindingDeviceId(
    MatrixLocalBinding binding, {
    required String expectedUserId,
    required String expectedHomeserver,
    required String nextDeviceId,
    required String? ed25519Fingerprint,
  }) async {
    if (binding.matrixUserId != expectedUserId) {
      throw const MatrixDeviceBindingRotationRejected('matrix-user');
    }
    if (binding.homeserver != expectedHomeserver) {
      throw const MatrixDeviceBindingRotationRejected('homeserver');
    }
    final existingFingerprint = binding.ed25519Fingerprint;
    if (existingFingerprint != null &&
        (ed25519Fingerprint == null ||
            ed25519Fingerprint.isEmpty ||
            existingFingerprint != ed25519Fingerprint)) {
      throw const MatrixDeviceBindingRotationRejected('fingerprint');
    }
    if (binding.deviceId == nextDeviceId) return binding;
    if (nextDeviceId.isEmpty) {
      throw const MatrixDeviceBindingRotationRejected('empty-device');
    }
    // version 2 的 binding 必须带 fingerprint；缺失时拒绝迁移而不是写出一个
    // 无法解析的 binding。
    final fingerprint = existingFingerprint ?? ed25519Fingerprint;
    if (fingerprint == null || fingerprint.isEmpty) {
      throw const MatrixDeviceBindingRotationRejected('fingerprint');
    }
    final migrated = MatrixLocalBinding(
      version: 2,
      matrixUserId: binding.matrixUserId,
      deviceId: nextDeviceId,
      homeserver: binding.homeserver,
      databaseGeneration: binding.databaseGeneration,
      ed25519Fingerprint: fingerprint,
    );
    await _saveMatrixBindingUnlocked(migrated);
    return migrated;
  }

  Future<MatrixLocalBinding?> matrixBinding() =>
      _runMatrixIdentityOperation(_matrixBindingUnlocked);

  Future<MatrixLocalBinding?> _matrixBindingUnlocked() async {
    final encoded = await _storage.read(_matrixBindingKey);
    if (encoded == null) return null;
    return _decodeMatrixBinding(encoded);
  }

  Future<String> matrixDatabaseKey() =>
      _runMatrixIdentityOperation(_matrixDatabaseKeyUnlocked);

  Future<String> _matrixDatabaseKeyUnlocked() async {
    final existing = await _storage.read(_matrixDatabaseKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _storage.write(_matrixDatabaseKey, value);
    return value;
  }

  Future<String> registrationDeviceKey() async {
    final existing = await _storage.read(_registrationDeviceKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await _storage.write(_registrationDeviceKey, value);
    return value;
  }

  Future<String> diagnosticSalt() =>
      _runMatrixIdentityOperation(_diagnosticSaltUnlocked);

  Future<String> _diagnosticSaltUnlocked() async {
    final existing = await _storage.read(_diagnosticSaltKey);
    if (existing != null) return _validateDiagnosticSalt(existing);
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await _storage.write(_diagnosticSaltKey, value);
    return value;
  }

  String _validateDiagnosticSalt(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]+={0,2}$').hasMatch(value)) {
      throw const FormatException('Invalid diagnostic salt');
    }
    late final List<int> decoded;
    try {
      decoded = base64Url.decode(base64Url.normalize(value));
    } on FormatException {
      throw const FormatException('Invalid diagnostic salt');
    }
    final canonical = base64UrlEncode(decoded).replaceAll('=', '');
    if (decoded.length != 32 || value.replaceAll('=', '') != canonical) {
      throw const FormatException('Invalid diagnostic salt');
    }
    return value;
  }

  Future<void> clearMatrixDatabaseKey() =>
      _runMatrixIdentityOperation(_clearMatrixDatabaseKeyUnlocked);

  Future<void> _clearMatrixDatabaseKeyUnlocked() =>
      _storage.delete(_matrixDatabaseKey);

  Future<void> saveEncryptedRecoveryKey(String value) =>
      _runMatrixIdentityOperation(
          () => _saveEncryptedRecoveryKeyUnlocked(value));

  Future<void> _saveEncryptedRecoveryKeyUnlocked(String value) =>
      _storage.write(
        _recoveryKey,
        base64Url.encode(utf8.encode(value)),
      );

  Future<String?> encryptedRecoveryKey() =>
      _runMatrixIdentityOperation(_encryptedRecoveryKeyUnlocked);

  Future<String?> _encryptedRecoveryKeyUnlocked() async {
    final value = await _storage.read(_recoveryKey);
    return value == null ? null : utf8.decode(base64Url.decode(value));
  }

  Future<void> clearMatrixIdentity() =>
      _runMatrixIdentityOperation(_clearMatrixIdentityUnlocked);

  Future<void> _clearMatrixIdentityUnlocked() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attemptDelete(String key) async {
      try {
        await _storage.delete(key);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attemptDelete(_recoveryKey);
    await attemptDelete(_matrixDatabaseKey);
    await attemptDelete(_diagnosticSaltKey);
    await attemptDelete(_matrixBindingKey);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// 全新安装时清除上一安装遗留的全部钥匙串状态。
  ///
  /// 这里必须作用于 `raw`：要删除的正是作用域指针与注册表本身，不能先经过
  /// 作用域间接层。加密库文件已随沙盒消失，因此删除全部槽不会丢失可读数据。
  Future<void> clearInstallation() =>
      _runMatrixIdentityOperation(_clearInstallationUnlocked,
          skipArchiveRecovery: true);

  Future<void> _clearInstallationUnlocked() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attemptDelete(String key) async {
      try {
        await _storage.raw.delete(key);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    for (final suffix in await _installationSlotSuffixes()) {
      for (final name in _scopedKeyNames) {
        await attemptDelete(suffix.isEmpty ? name : '$name.$suffix');
      }
    }
    // A failed scoped deletion must leave the registry and active-scope
    // pointer intact. They are the only durable enumeration path for every
    // account suffix; deleting them after a partial failure would make the
    // next startup unable to retry the failed scoped key.
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    for (final key in _slotIndependentKeys) {
      await attemptDelete(key);
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    // Archive enumeration survives every partial deletion. The journal is
    // removed before the index, and only after all scoped keys are gone.
    await attemptDelete(_matrixArchiveJournalKey);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
    await attemptDelete(_matrixArchiveIndexKey);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// 候选槽后缀：空后缀（ADR-0063 之前的单账号遗留）加上注册表中出现的槽。
  /// 注册表损坏不得阻断清除——此时"全新安装"这个判断已经成立，损坏只影响
  /// 枚举方式，退化为从原始值中提取全部 64 位十六进制串。
  Future<Set<String>> _installationSlotSuffixes() async {
    final suffixes = <String>{''};
    for (final key in [
      _AccountScopedSecureStore.registryKey,
      _AccountScopedSecureStore.activeKey,
      _matrixArchiveIndexKey,
      _matrixArchiveJournalKey,
    ]) {
      final encoded = await _storage.peekRaw(key);
      if (encoded == null) continue;
      // This cleanup is reachable only after the installation generation
      // probe established that no DB/WAL/SHM survives. Extracting hash-like
      // tokens also keeps malformed legacy metadata retryable.
      suffixes.addAll(
          _hashToken.allMatches(encoded).map((match) => match.group(0)!));
    }
    return suffixes;
  }

  Future<void> clear() async {
    await clearBusinessSession();
    await clearMatrixIdentity();
    await _storage.delete(_legacyAccessKey);
    await _storage.delete(_legacyRefreshKey);
  }
}

/// Matrix material is scoped; the single current business session is not.
final class _AccountScopedSecureStore implements SecureKeyValueStore {
  _AccountScopedSecureStore(this.raw);
  final SecureKeyValueStore raw;
  static const activeKey = 'liuhetong.active_matrix_scope.v1';
  static const registryKey = 'liuhetong.matrix_account_slots.v1';
  static final _hash = RegExp(r'^[a-f0-9]{64}$');
  static const _scoped = {
    'liuhetong.matrix_database_key.v1',
    'liuhetong.matrix_local_binding.v1',
    'liuhetong.encrypted_recovery_key',
    'liuhetong.diagnostic_salt.v1',
    'liuhetong.matrix_clear_tombstone.v1',
  };
  static String identity(String homeserver, String userId) =>
      sha256.convert(utf8.encode(jsonEncode([homeserver, userId]))).toString();
  Future<String?> peekRaw(String key) async =>
      raw is PeekableSecureKeyValueStore
          ? (raw as PeekableSecureKeyValueStore).peek(key)
          : raw.read(key);

  Future<Map<String, String>> slots() => _slots(raw.read);
  Future<Map<String, String>> peekSlots() => _slots(peekRaw);

  Future<Map<String, String>> _slots(
      Future<String?> Function(String key) readKey) async {
    final encoded = await readKey(registryKey);
    if (encoded == null) return {};
    final parsed = jsonDecode(encoded);
    if (parsed is! Map<String, dynamic> ||
        parsed.entries.any((entry) =>
            !_hash.hasMatch(entry.key) ||
            entry.value is! String ||
            (entry.value != '' && !_hash.hasMatch(entry.value as String)))) {
      throw const FormatException('Invalid Matrix account registry');
    }
    final result = parsed.cast<String, String>();
    if (result.values.toSet().length != result.length) {
      throw const FormatException('Aliased Matrix account registry');
    }
    return result;
  }

  Future<String> scope() => _scope(raw.read, slots);
  Future<String> peekScope() => _scope(peekRaw, peekSlots);

  Future<String> _scope(Future<String?> Function(String key) readKey,
      Future<Map<String, String>> Function() readSlots) async {
    final value = await readKey(activeKey);
    final registered = await readSlots();
    if (value == null) return '';
    if ((value.isNotEmpty && !_hash.hasMatch(value)) ||
        !registered.containsValue(value)) {
      throw const FormatException('Invalid active Matrix account');
    }
    return value;
  }

  Future<String> _key(String key) async {
    if (!_scoped.contains(key)) return key;
    final suffix = await scope();
    return suffix.isEmpty ? key : '$key.$suffix';
  }

  @override
  Future<String?> read(String key) async => raw.read(await _key(key));
  @override
  Future<void> write(String key, String value) async =>
      raw.write(await _key(key), value);
  @override
  Future<void> delete(String key) async => raw.delete(await _key(key));
}
