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

final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
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

final class StoredBusinessSession {
  const StoredBusinessSession({
    required this.version,
    required this.accessToken,
    required this.refreshToken,
    this.matrixUserId,
    this.deviceKey,
  });

  final int version;
  final String accessToken;
  final String refreshToken;
  final String? matrixUserId;
  final String? deviceKey;

  @override
  bool operator ==(Object other) =>
      other is StoredBusinessSession &&
      other.version == version &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.matrixUserId == matrixUserId &&
      other.deviceKey == deviceKey;

  @override
  int get hashCode =>
      Object.hash(version, accessToken, refreshToken, matrixUserId, deviceKey);
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

  Future<String> matrixStorageScope() =>
      _runMatrixIdentityOperation(_storage.scope);

  /// Only called after business authentication and the old client has closed.
  Future<void> selectMatrixAccount(String homeserver, String userId) =>
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
  }) =>
      _storage.write(
        _sessionKey,
        jsonEncode({
          'version': 1,
          'access_token': accessToken,
          'refresh_token': refreshToken,
          if (matrixUserId != null) 'matrix_user_id': matrixUserId,
          if (deviceKey != null) 'device_key': deviceKey,
        }),
      );

  Future<StoredBusinessSession?> session() async {
    final encoded = await _storage.read(_sessionKey);
    if (encoded != null) {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['access_token'] is! String ||
          value['refresh_token'] is! String) {
        throw const FormatException('Invalid stored business session');
      }
      return StoredBusinessSession(
        version: 1,
        accessToken: value['access_token'] as String,
        refreshToken: value['refresh_token'] as String,
        matrixUserId: value['matrix_user_id']?.toString(),
        deviceKey: value['device_key']?.toString(),
      );
    }
    return _migrateLegacySession();
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

  Future<T> _runMatrixIdentityOperation<T>(
    Future<T> Function() operation,
  ) {
    final result = _matrixIdentityOperations.then<T>((_) => operation());
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

  Future<MatrixLocalBinding?> matrixBinding() =>
      _runMatrixIdentityOperation(_matrixBindingUnlocked);

  Future<MatrixLocalBinding?> _matrixBindingUnlocked() async {
    final encoded = await _storage.read(_matrixBindingKey);
    if (encoded == null) return null;
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid matrix local binding');
    }
    return MatrixLocalBinding.fromJson(value);
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
  Future<Map<String, String>> slots() async {
    final encoded = await raw.read(registryKey);
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

  Future<String> scope() async {
    final value = await raw.read(activeKey);
    final registered = await slots();
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
