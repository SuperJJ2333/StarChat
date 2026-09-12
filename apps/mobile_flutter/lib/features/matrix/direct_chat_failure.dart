import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import 'package:liuhetong_mobile/core/business_api_error.dart';
import 'package:matrix/matrix.dart';

import 'coordinated_direct_chat.dart';

/// 问题三：好友页“发消息”失败此前统一渲染为“无法打开加密会话/请检查
/// 网络后重试”，同步滞后、好友映射缺失、网络错误不可区分且无重试入口。
/// 本文件给出失败分类（不含任何敏感信息：房间号/Matrix ID/网络细节
/// 仍只进 developer.log 结构化诊断）与对应文案、重试策略。
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

  /// 网络或其它可恢复失败。
  networkOrOther,
}

DirectChatFailureKind classifyDirectChatFailure(Object? error) {
  if (error is DirectRoomPendingException) {
    return DirectChatFailureKind.syncPending;
  }
  if (error is TimeoutException) return DirectChatFailureKind.requestTimedOut;
  if (error is StateError &&
      error.message == 'The contact is no longer a current friend') {
    return DirectChatFailureKind.contactUnavailable;
  }
  if (error is SocketException || error is http.ClientException) {
    return DirectChatFailureKind.offline;
  }
  final statusCode = switch (error) {
    BusinessApiException error => error.statusCode,
    MatrixException error => error.response?.statusCode,
    _ => null,
  };
  if (statusCode == 401) return DirectChatFailureKind.authenticationRequired;
  if (statusCode == 403) return DirectChatFailureKind.permissionDenied;
  return DirectChatFailureKind.networkOrOther;
}

String describeDirectChatFailure(Object? error) =>
    switch (classifyDirectChatFailure(error)) {
      DirectChatFailureKind.syncPending => '对方会话还在同步中，请稍后重试。',
      DirectChatFailureKind.requestTimedOut => '打开会话超时，请检查网络后重试。',
      DirectChatFailureKind.contactUnavailable => '该好友已不在你的好友列表。',
      DirectChatFailureKind.offline => '当前处于离线状态，请恢复网络后重试。',
      DirectChatFailureKind.authenticationRequired => '登录状态已失效，请重新登录。',
      DirectChatFailureKind.permissionDenied => '你没有权限打开此会话。',
      DirectChatFailureKind.networkOrOther => '无法打开会话，请稍后重试。',
    };

/// 统一的私聊打开失败弹窗：保留原错误标题（用户/客服对齐口径），
/// 按类别给出真实失败状态；除好友映射缺失（重试必然再失败）外提供
/// “重试”，点击后先收起弹窗再执行调用方的打开流程。
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
      title: const Text('无法打开加密会话'),
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
