import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
final class SecureSessionStore {
  SecureSessionStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _accessKey = 'liuhetong.access_token';
  static const _refreshKey = 'liuhetong.refresh_token';
  static const _recoveryKey = 'liuhetong.encrypted_recovery_key';
  Future<void> saveSession({required String accessToken, required String refreshToken}) async { await _storage.write(key: _accessKey, value: accessToken); await _storage.write(key: _refreshKey, value: refreshToken); }
  Future<String?> accessToken() => _storage.read(key: _accessKey);
  Future<String?> refreshToken() => _storage.read(key: _refreshKey);
  Future<void> saveEncryptedRecoveryKey(String value) => _storage.write(key: _recoveryKey, value: base64Url.encode(utf8.encode(value)));
  Future<String?> encryptedRecoveryKey() async { final value = await _storage.read(key: _recoveryKey); return value == null ? null : utf8.decode(base64Url.decode(value)); }
  Future<void> clear() => _storage.deleteAll();
}
