import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix_api_lite.dart' show MatrixException;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show DatabaseException;

/// Only an allowlisted category leaves the error boundary. Exception messages,
/// platform details and Matrix response bodies must never become UI text.
enum SessionFailureCategory {
  protectedData,
  keychainPermission,
  platform,
  metadata,
  database,
  filesystem,
  matrixIdentity,
  matrixCredentials,
  matrixRejected,
  matrixRateLimited,
  matrixService,
  network,
  unknown,
}

SessionFailureCategory classifySessionFailure(Object error) {
  if (error is PlatformException) {
    if (error.code == 'secure_session_integrity') {
      return SessionFailureCategory.metadata;
    }
    final details = error.details;
    final nativeStatus = error.code == 'secure_session_status' && details is Map
        ? details['status']
        : null;
    final status = (nativeStatus is int ? nativeStatus : null) ??
        int.tryParse(error.code) ??
        (error.code == 'Unexpected security result code' && error.details is int
            ? error.details as int
            : null);
    if (status == -25308 || error.code == 'PROTECTED_DATA_UNAVAILABLE') {
      return SessionFailureCategory.protectedData;
    }
    if (status == -34018) return SessionFailureCategory.keychainPermission;
    return SessionFailureCategory.platform;
  }
  // These fixed StateError messages are the current local continuity contract.
  // Match whole values only; never copy/interpolate the error into the UI.
  if (error is StateError &&
      const {
        'Stored Matrix identity does not match authenticated account',
        'Matrix client does not match the local binding',
        'Matrix account homeserver mismatch',
        'Matrix continuity identity is unavailable',
        'Matrix login returned an unexpected identity',
      }.contains(error.message)) {
    return SessionFailureCategory.matrixIdentity;
  }
  if (error is FormatException) return SessionFailureCategory.metadata;
  if (error is DatabaseException) return SessionFailureCategory.database;
  if (error is FileSystemException) return SessionFailureCategory.filesystem;
  if (error is MatrixException) {
    return switch (error.errcode) {
      'M_UNKNOWN_TOKEN' ||
      'M_MISSING_TOKEN' ||
      'M_UNAUTHORIZED' =>
        SessionFailureCategory.matrixCredentials,
      'M_FORBIDDEN' ||
      'M_USER_DEACTIVATED' =>
        SessionFailureCategory.matrixRejected,
      'M_LIMIT_EXCEEDED' => SessionFailureCategory.matrixRateLimited,
      _ => SessionFailureCategory.matrixService,
    };
  }
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is HandshakeException) {
    return SessionFailureCategory.network;
  }
  return SessionFailureCategory.unknown;
}

String sessionFailureMessage(Object error, {required String stage}) =>
    sessionFailureCategoryMessage(classifySessionFailure(error), stage: stage);

String sessionFailureCategoryMessage(SessionFailureCategory category,
    {required String stage}) {
  return switch (category) {
    SessionFailureCategory.protectedData => '设备安全存储暂不可访问，请解锁手机后重试',
    SessionFailureCategory.keychainPermission => '安全存储访问权限异常，请联系支持检查应用安装与签名',
    SessionFailureCategory.platform => '系统存储服务暂不可用，请稍后重试',
    SessionFailureCategory.metadata => '本地账号记录无法读取，请重试；若仍失败，请联系支持',
    SessionFailureCategory.database => '本地聊天数据库无法打开，请解锁手机后重试；若仍失败，请联系支持',
    SessionFailureCategory.filesystem => '本地聊天存储无法访问，请解锁手机后重试；若仍失败，请联系支持',
    SessionFailureCategory.matrixIdentity => '本地聊天身份校验未通过，请重试；若仍失败，请联系支持',
    SessionFailureCategory.matrixCredentials => '聊天登录凭据已失效，请重新登录',
    SessionFailureCategory.matrixRejected => '聊天服务拒绝登录，请联系支持检查账号状态',
    SessionFailureCategory.matrixRateLimited => '聊天登录请求过于频繁，请稍后重试',
    SessionFailureCategory.matrixService => '聊天服务暂时无法完成请求，请稍后重试',
    SessionFailureCategory.network => '网络连接中断，请检查网络后重试',
    SessionFailureCategory.unknown => switch (stage) {
        'startup' => '应用启动时无法读取本地会话，请解锁手机后重试',
        'local_restore' => '本地聊天会话恢复未完成，请解锁手机后重试',
        'local_identity' => '本地账号身份无法读取，请重试；若仍失败，请联系支持',
        'matrix_grant' => '聊天登录凭据获取失败，请稍后重试',
        'switch_local_clear' => '本地聊天账号切换未完成，请重试',
        'matrix_login' => '聊天身份验证未完成，请重试；若仍失败，请联系支持',
        'matrix_sync' => '聊天同步未完成，请重试',
        'identity_binding' => '聊天账号绑定未完成，请重试',
        'account_storage' => '本地账号存储暂不可用，请解锁手机后重试',
        'matrix_session' => '聊天设备会话确认未完成，请重试',
        _ => '会话恢复未完成，请重试；若仍失败，请联系支持',
      },
  };
}
