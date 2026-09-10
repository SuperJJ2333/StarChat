import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'coordinated_direct_chat.dart';

/// 问题三：好友页“发消息”失败此前统一渲染为“无法打开加密会话/请检查
/// 网络后重试”，同步滞后、好友映射缺失、网络错误不可区分且无重试入口。
/// 本文件给出失败分类（不含任何敏感信息：房间号/Matrix ID/网络细节
/// 仍只进 developer.log 结构化诊断）与对应文案、重试策略。
enum DirectChatFailureKind {
  /// 同步尚未完成（规范房间/成员/加密状态还在路上）——稍后重试可恢复。
  syncPending,

  /// 好友映射缺失（已不是当前好友）——重试无意义。
  contactUnavailable,

  /// 网络或其它可恢复失败。
  networkOrOther,
}

DirectChatFailureKind classifyDirectChatFailure(Object? error) {
  if (error is TimeoutException || error is DirectRoomPendingException) {
    return DirectChatFailureKind.syncPending;
  }
  if (error is StateError &&
      error.message == 'The contact is no longer a current friend') {
    return DirectChatFailureKind.contactUnavailable;
  }
  return DirectChatFailureKind.networkOrOther;
}

String describeDirectChatFailure(Object? error) =>
    switch (classifyDirectChatFailure(error)) {
      DirectChatFailureKind.syncPending => '对方会话还在同步中，请稍后重试。',
      DirectChatFailureKind.contactUnavailable => '该好友已不在你的好友列表。',
      DirectChatFailureKind.networkOrOther => '网络异常，请稍后重试。',
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
      classifyDirectChatFailure(error) !=
          DirectChatFailureKind.contactUnavailable;
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
