import 'package:flutter/cupertino.dart';

import '../foundation/wechat_tokens.dart';

enum ConversationAction { markUnread, togglePin, hide, delete }

Future<ConversationAction?> showConversationActionSheet(
  BuildContext context, {
  required bool pinned,
  required ValueChanged<ConversationAction> onAction,
}) =>
    showCupertinoModalPopup<ConversationAction>(
      context: context,
      builder: (sheetContext) => CupertinoActionSheet(
        actions: [
          _item(sheetContext, CupertinoIcons.circle, '标记未读',
              ConversationAction.markUnread),
          _item(
              sheetContext,
              pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
              pinned ? '取消置顶' : '置顶该聊天',
              ConversationAction.togglePin),
          _item(sheetContext, CupertinoIcons.eye_slash, '不显示该聊天',
              ConversationAction.hide),
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () =>
                Navigator.pop(sheetContext, ConversationAction.delete),
            child: const Text('删除该聊天'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheetContext),
          child: const Text('取消'),
        ),
      ),
    ).then((value) {
      if (value != null) onAction(value);
      return value;
    });

CupertinoActionSheetAction _item(
  BuildContext context,
  IconData icon,
  String label,
  ConversationAction action,
) =>
    CupertinoActionSheetAction(
      onPressed: () => Navigator.pop(context, action),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: WeChatColors.lightTextPrimary),
          const SizedBox(width: WeChatSpacing.sm),
          Text(label),
        ],
      ),
    );
