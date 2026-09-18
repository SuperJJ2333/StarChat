import 'package:flutter/cupertino.dart';

import 'room_opening_policy.dart';

/// 打开会话失败的**统一用户反馈**。
///
/// 架构要求（审计 P1-1 / P1-2）：
/// - 打开失败必须**用户可见**——不允许 `catch (_) {}` 让"点了没反应"；
/// - 文案只有一处来源（[RoomOpenFailure.userMessage]），任何入口都不自造；
/// - 所有入口（消息列表、搜索、通知/推送/横幅、扫码、好友通过、群聊通讯录）
///   都经组合根调用本函数，因此提示样式与行为一致。
///
/// 与策略层的关系：`RoomOpeningPolicy` 只负责"判定 + 分类"，不碰 UI；
/// 本函数是策略结论到用户可见提示的唯一投影点。
Future<void> showRoomOpenFailureDialog(
  BuildContext context,
  RoomOpenFailure failure,
) {
  if (!context.mounted) return Future<void>.value();
  return showCupertinoDialog<void>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      key: const Key('room-open-failure'),
      title: const Text('无法打开会话'),
      content: Text(failure.userMessage),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}
