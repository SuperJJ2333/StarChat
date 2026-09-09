import 'package:flutter/cupertino.dart';
import '../components/anchored_action_menu.dart';

enum ConversationAction { markUnread, togglePin, hide, delete }

Future<ConversationAction?> showConversationActionSheet(
  BuildContext context, {
  required bool pinned,
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
        const AnchoredMenuItem(
            value: ConversationAction.markUnread,
            icon: CupertinoIcons.circle,
            label: '标记未读'),
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
