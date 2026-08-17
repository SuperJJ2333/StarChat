import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  FlutterSecureKeyValueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

final class StoredBusinessSession {
  const StoredBusinessSession({
    required this.version,
    required this.accessToken,
    required this.refreshToken,
    this.matrixUserId,
  });

  final int version;
  final String accessToken;
  final String refreshToken;
  final String? matrixUserId;

  @override
  bool operator ==(Object other) =>
      other is StoredBusinessSession &&
      other.version == version &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.matrixUserId == matrixUserId;

  @override
  int get hashCode =>
      Object.hash(version, accessToken, refreshToken, matrixUserId);
}

final class SecureSessionStore {
  SecureSessionStore([SecureKeyValueStore? storage])
      : _storage = storage ?? FlutterSecureKeyValueStore();

  final SecureKeyValueStore _storage;

  static const _sessionKey = 'liuhetong.business_session.v1';
  static const _legacyAccessKey = 'liuhetong.access_token';
  static const _legacyRefreshKey = 'liuhetong.refresh_token';
  static const _recoveryKey = 'liuhetong.encrypted_recovery_key';
  static const _matrixDatabaseKey = 'liuhetong.matrix_database_key.v1';

  Future<void> saveSession({
    required String accessToken,
    required String refreshToken,
    String? matrixUserId,
  }) =>
      _storage.write(
        _sessionKey,
        jsonEncode({
          'version': 1,
          'access_token': accessToken,
          'refresh_token': refreshToken,
          if (matrixUserId != null) 'matrix_user_id': matrixUserId,
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
    );
  }

  Future<String?> accessToken() async => (await session())?.accessToken;
  Future<String?> refreshToken() async => (await session())?.refreshToken;

  Future<void> clearBusinessSession() => _storage.delete(_sessionKey);

  Future<String> matrixDatabaseKey() async {
    final existing = await _storage.read(_matrixDatabaseKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final value = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await _storage.write(_matrixDatabaseKey, value);
    return value;
  }

  Future<void> clearMatrixDatabaseKey() => _storage.delete(_matrixDatabaseKey);

  Future<void> saveEncryptedRecoveryKey(String value) => _storage.write(
        _recoveryKey,
        base64Url.encode(utf8.encode(value)),
      );

  Future<String?> encryptedRecoveryKey() async {
    final value = await _storage.read(_recoveryKey);
    return value == null ? null : utf8.decode(base64Url.decode(value));
  }

  Future<void> clear() async {
    await clearBusinessSession();
    await clearMatrixDatabaseKey();
    await _storage.delete(_recoveryKey);
    await _storage.delete(_legacyAccessKey);
    await _storage.delete(_legacyRefreshKey);
  }
}
