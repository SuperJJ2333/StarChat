import 'package:flutter/cupertino.dart';
import '../components/anchored_action_menu.dart';

enum ConversationAction { markUnread, clearUnread, togglePin, hide, delete }

Future<ConversationAction?> showConversationActionSheet(
  BuildContext context, {
  required bool pinned,
  required bool manualUnread,
  required ValueChanged<ConversationAction> onAction,
  Rect? anchor,
}) async {
  final value = await showAnchoredActionMenu<ConversationAction>(context,
      anchor: anchor,
      items: [
        AnchoredMenuItem(
            value: ConversationAction.togglePin,
            icon: pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
            label: pinned ? '取消置顶' : '置顶该聊天'),
        // BUG-15：已标未读的会话显示「取消未读」，不再重复提供「标记未读」。
        AnchoredMenuItem(
            value: manualUnread
                ? ConversationAction.clearUnread
                : ConversationAction.markUnread,
            icon:
                manualUnread ? CupertinoIcons.circle_fill : CupertinoIcons.circle,
            label: manualUnread ? '取消未读' : '标记未读'),
        const AnchoredMenuItem(
            value: ConversationAction.hide,
            icon: CupertinoIcons.eye_slash,
            label: '不显示该聊天'),
        const AnchoredMenuItem(
            value: ConversationAction.delete,
            icon: CupertinoIcons.trash,
            label: '删除该聊天'),
      ]);
  if (value != null && context.mounted) onAction(value);
  return value;
}
