import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:matrix/matrix.dart';

import 'coordinated_direct_chat.dart';

/// 失败分类（不含任何敏感信息：房间号/Matrix ID/网络细节
/// 仍只进 developer.log 结构化诊断）。
///
/// 2026-09-18 Offline First：按**错误类型**给用户可执行的信息，
/// 不再对所有失败统一显示“无法打开加密会话”。分类词表与产品要求一致：
/// offline / weak / server / crypto（其余保留既有语义）。
enum DirectChatFailureKind {
  /// 已知规范房间还在同步——稍后重试可恢复。
  syncPending,

  /// A request elapsed without proving whether the room is still syncing.
  requestTimedOut,

  /// 好友映射缺失（已不是当前好友）——重试无意义。
  contactUnavailable,

  /// The device cannot reach the transport. HTTP authorization and Matrix
  /// protocol errors deliberately do not enter this bucket.
  offline,

  /// Business or Matrix credentials have expired. Retrying the same action
  /// cannot renew them.
  authenticationRequired,

  /// The current account is not allowed to open the selected room.
  permissionDenied,

  /// 加密会话尚未就绪（成员或加密状态校验失败、房间登记未完成）。
  crypto,

  /// 服务端明确失败（5xx / 服务不可用）。
  server,

  /// 网络不稳定（超时，但链路仍可用）。
  weak,

  /// 网络或其它可恢复失败。
  networkOrOther,
}

/// 服务端失败的最小判定：HTTP 5xx 或明确的服务不可用。
bool _isServerFailure(int? statusCode) => statusCode != null && statusCode >= 500;

DirectChatFailureKind classifyDirectChatFailure(Object? error) {
  if (error is DirectRoomPendingException) {
    return DirectChatFailureKind.syncPending;
  }
  final statusCode = switch (error) {
    BusinessApiException error => error.statusCode,
    MatrixException error => error.response?.statusCode,
    _ => null,
  };
  if (_isServerFailure(statusCode)) return DirectChatFailureKind.server;
  if (statusCode == 401) return DirectChatFailureKind.authenticationRequired;
  if (statusCode == 403) return DirectChatFailureKind.permissionDenied;
  if (error is TimeoutException) return DirectChatFailureKind.weak;
  if (error is StateError && _isCryptoNotReady(error.message)) {
    return DirectChatFailureKind.crypto;
  }
  if (error is StateError &&
      error.message == 'The contact is no longer a current friend') {
    return DirectChatFailureKind.contactUnavailable;
  }
  if (error is SocketException || error is http.ClientException) {
    return DirectChatFailureKind.offline;
  }
  return DirectChatFailureKind.networkOrOther;
}

/// 加密/成员就绪类失败：这些是**会话状态**问题，不是网络问题。
bool _isCryptoNotReady(String message) =>
    message.contains('规范私聊成员或加密状态尚未就绪') ||
    message.contains('规范私聊登记未完成') ||
    message.contains('Direct chat must be encrypted') ||
    message.contains('Direct chat is not ready') ||
    message.contains('Matrix room is unavailable');

/// 用户可见文案（产品要求的分类词表）。
String describeDirectChatFailure(Object? error) =>
    switch (classifyDirectChatFailure(error)) {
      DirectChatFailureKind.syncPending => '对方会话还在同步中，请稍后重试。',
      DirectChatFailureKind.requestTimedOut => '网络不稳定，请稍候。',
      DirectChatFailureKind.contactUnavailable => '该好友已不在你的好友列表。',
      DirectChatFailureKind.offline => '当前没有网络，消息将在恢复后同步。',
      DirectChatFailureKind.authenticationRequired => '登录状态已失效，请重新登录。',
      DirectChatFailureKind.permissionDenied => '你没有权限打开此会话。',
      DirectChatFailureKind.crypto => '安全会话初始化失败，请稍后重试。',
      DirectChatFailureKind.server => '服务器连接失败，请稍后重试。',
      DirectChatFailureKind.weak => '网络不稳定，请稍候。',
      DirectChatFailureKind.networkOrOther => '网络不稳定，请稍候。',
    };

/// 弹窗标题：按类型区分，且**不再使用**“无法打开加密会话”。
String titleDirectChatFailure(Object? error) =>
    switch (classifyDirectChatFailure(error)) {
      DirectChatFailureKind.contactUnavailable => '无法打开会话',
      DirectChatFailureKind.authenticationRequired => '登录状态已失效',
      DirectChatFailureKind.permissionDenied => '无法打开会话',
      DirectChatFailureKind.offline => '当前没有网络',
      DirectChatFailureKind.weak ||
      DirectChatFailureKind.requestTimedOut ||
      DirectChatFailureKind.networkOrOther =>
        '网络不稳定',
      DirectChatFailureKind.crypto => '安全会话初始化失败',
      DirectChatFailureKind.server => '服务器连接失败',
      DirectChatFailureKind.syncPending => '会话正在同步',
    };

/// 统一的私聊打开失败弹窗：标题与内容都按失败类型区分；除好友映射缺失、
/// 登录失效、无权限（重试必然再失败）外提供“重试”。
Future<void> showDirectChatFailureDialog(
  BuildContext context,
  Object? error, {
  Future<void> Function()? onRetry,
}) {
  final retryable = onRetry != null &&
      !{
        DirectChatFailureKind.contactUnavailable,
        DirectChatFailureKind.authenticationRequired,
        DirectChatFailureKind.permissionDenied,
      }.contains(classifyDirectChatFailure(error));
  return showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(titleDirectChatFailure(error)),
      content: Text(describeDirectChatFailure(error)),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
        if (retryable)
          CupertinoDialogAction(
            onPressed: () {
              Navigator.pop(dialogContext);
              onRetry();
            },
            child: const Text('重试'),
          ),
      ],
    ),
  );
}
