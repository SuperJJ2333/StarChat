import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/session_failure.dart';
import 'package:matrix/matrix_api_lite.dart' show MatrixException;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseException;

void main() {
  test(
      'native secure session bridge OSStatus and integrity errors are recognized',
      () {
    final failures = <Object, SessionFailureCategory>{
      PlatformException(
              code: 'secure_session_status',
              details: {'status': -25308, 'secret': 'token'}):
          SessionFailureCategory.protectedData,
      PlatformException(
              code: 'secure_session_status', details: {'status': -34018}):
          SessionFailureCategory.keychainPermission,
      PlatformException(code: 'secure_session_integrity', message: 'secret'):
          SessionFailureCategory.metadata,
      PlatformException(
              code: 'secure_session_status',
              details: {'status': 'secret -25308'}):
          SessionFailureCategory.platform,
      PlatformException(code: 'unknown', details: {'status': -25308}):
          SessionFailureCategory.platform,
    };
    for (final entry in failures.entries) {
      expect(classifySessionFailure(entry.key), entry.value);
      expect(sessionFailureMessage(entry.key, stage: 'account_storage'),
          isNot(contains('secret')));
    }
  });
  test('known local Matrix identity mismatches are actionable without raw text',
      () {
    for (final message in [
      'Stored Matrix identity does not match authenticated account',
      'Matrix client does not match the local binding',
      'Matrix account homeserver mismatch',
      'Matrix continuity identity is unavailable',
      'Matrix login returned an unexpected identity',
    ]) {
      final display =
          sessionFailureMessage(StateError(message), stage: 'account_storage');
      expect(display, contains('身份'));
      expect(display, contains('联系支持'));
      expect(display, isNot(contains(message)));
    }
    expect(
        classifySessionFailure(StateError(
            'Matrix client does not match the local binding secret token')),
        SessionFailureCategory.unknown);
  });

  test('startup and local restore failures identify the failed operation', () {
    expect(sessionFailureMessage(StateError('secret'), stage: 'startup'),
        contains('启动'));
    expect(sessionFailureMessage(StateError('secret'), stage: 'local_restore'),
        contains('本地聊天会话'));
  });

  test('real secure storage status details and bridge code classify safely',
      () {
    for (final error in [
      PlatformException(
          code: 'Unexpected security result code', details: -25308),
      PlatformException(code: 'PROTECTED_DATA_UNAVAILABLE'),
    ]) {
      expect(
          classifySessionFailure(error), SessionFailureCategory.protectedData);
    }
    expect(
        classifySessionFailure(PlatformException(
            code: 'Unexpected security result code', details: -34018)),
        SessionFailureCategory.keychainPermission);
    // Do not search arbitrary details or free text for security status codes.
    expect(
        classifySessionFailure(PlatformException(
            code: 'unknown', message: '-25308', details: {'secret': -34018})),
        SessionFailureCategory.platform);
  });

  test('storage, transport and Matrix errors retain safe categories', () {
    final failures = <Object, SessionFailureCategory>{
      _DatabaseFailure('secret sql'): SessionFailureCategory.database,
      const FileSystemException('secret path'):
          SessionFailureCategory.filesystem,
      const FormatException('secret metadata'): SessionFailureCategory.metadata,
      TimeoutException('secret url'): SessionFailureCategory.network,
      http.ClientException('secret token'): SessionFailureCategory.network,
      const HandshakeException('secret host'): SessionFailureCategory.network,
      MatrixException.fromJson(
              {'errcode': 'M_UNKNOWN_TOKEN', 'error': 'secret token'}):
          SessionFailureCategory.matrixCredentials,
      MatrixException.fromJson(
              {'errcode': 'M_FORBIDDEN', 'error': 'secret body'}):
          SessionFailureCategory.matrixRejected,
      MatrixException.fromJson(
              {'errcode': 'M_LIMIT_EXCEEDED', 'error': 'secret body'}):
          SessionFailureCategory.matrixRateLimited,
      MatrixException.fromJson(
              {'errcode': 'secret code', 'error': 'secret body'}):
          SessionFailureCategory.matrixService,
      StateError('secret token'): SessionFailureCategory.unknown,
    };
    for (final entry in failures.entries) {
      expect(classifySessionFailure(entry.key), entry.value);
      final message = sessionFailureMessage(entry.key, stage: 'secret stage');
      expect(message, isNot(contains('secret')));
      expect(message, isNot(matches(RegExp(r'L0[0-9]'))));
      expect(message, contains('请'));
    }
  });
}

final class _DatabaseFailure extends DatabaseException {
  _DatabaseFailure(super.message);
  @override
  bool isNoSuchTableError([String? table]) => false;
  @override
  bool isSyntaxError() => false;
  @override
  bool isDatabaseClosedError() => false;
  @override
  bool isOpenFailedError() => false;
  @override
  bool isReadOnlyError() => false;
  @override
  bool isUniqueConstraintError([String? field]) => false;
  @override
  bool isNotNullConstraintError([String? field]) => false;
  @override
  int? getResultCode() => null;
  @override
  Object? get result => null;
}
