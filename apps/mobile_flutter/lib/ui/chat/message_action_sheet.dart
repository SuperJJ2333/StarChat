import 'package:flutter/cupertino.dart';

import 'message_action.dart';

final class MessageActionSheet extends StatelessWidget {
  const MessageActionSheet({
    super.key,
    required this.actions,
    required this.onSelected,
  });

  final Set<MessageAction> actions;
  final ValueChanged<MessageAction> onSelected;

  // BUG-32（真机回归修订）：引用图标为双引号字形（微信式），不是回复箭头
  // 或引用气泡。撤回的红色在此一并给出（图标改为 Widget 后不再走特殊分支）。
  static const _presentation = <MessageAction, (Widget, String)>{
    MessageAction.voiceEarpiece: (Icon(CupertinoIcons.phone), '听筒播放'),
    MessageAction.voiceSpeaker: (Icon(CupertinoIcons.speaker_2), '扬声器播放'),
    MessageAction.addToEmoji: (Icon(CupertinoIcons.star), '收藏'),
    MessageAction.forward:
        (Icon(CupertinoIcons.arrowshape_turn_up_right), '转发'),
    MessageAction.deleteLocal: (Icon(CupertinoIcons.delete), '删除'),
    MessageAction.multiSelect: (Icon(CupertinoIcons.checkmark_square), '多选'),
    MessageAction.reply: (
      Text(
        '””',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 18,
          height: 26 / 18,
          fontWeight: FontWeight.w800,
        ),
      ),
      '引用'
    ),
    MessageAction.reminder: (Icon(CupertinoIcons.alarm), '提醒'),
    MessageAction.recall: (
      Icon(
        CupertinoIcons.arrow_uturn_left,
        color: CupertinoColors.systemRed,
      ),
      '撤回'
    ),
  };

  @override
  Widget build(BuildContext context) => CupertinoPopupSurface(
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: actions.length <= 4 ? 116 : 206,
            child: GridView.count(
              padding: const EdgeInsets.all(12),
              crossAxisCount: 4,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final action in actions)
                  _ActionButton(
                    action: action,
                    presentation: _presentation[action]!,
                    onPressed: () => onSelected(action),
                  ),
              ],
            ),
          ),
        ),
      );
}

final class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.action,
    required this.presentation,
    required this.onPressed,
  });

  final MessageAction action;
  final (Widget, String) presentation;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (iconWidget, label) = presentation;
    final destructive = action == MessageAction.recall;
    return CupertinoButton(
      key: Key('message-action-${action.name}'),
      minimumSize: const Size.square(44),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(dimension: 26, child: Center(child: iconWidget)),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: destructive ? CupertinoColors.systemRed : null,
            ),
          ),
        ],
      ),
    );
  }
}

final class MessageSelectionBar extends StatelessWidget {
  const MessageSelectionBar({
    super.key,
    required this.count,
    required this.canForward,
    required this.onForward,
    required this.onDelete,
    required this.onCancel,
    this.onCopy,
  });

  final int count;
  final bool canForward;
  final VoidCallback onForward;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  /// 多选复制：合并所选文本消息（emoji 按映射表转 [表情名称]）。
  /// 传入即显示复制按钮；未传（如纯媒体场景）保持原布局。
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) => Container(
        height: 58,
        decoration: BoxDecoration(
          color: CupertinoTheme.of(context).barBackgroundColor,
          border: Border(
            top: BorderSide(
                color: CupertinoColors.separator.resolveFrom(context),
                width: .5),
          ),
        ),
        child: Row(
          children: [
            CupertinoButton(
              key: const Key('selection-cancel'),
              onPressed: onCancel,
              child: const Text('取消'),
            ),
            if (onCopy != null)
              CupertinoButton(
                key: const Key('selection-copy'),
                onPressed: count == 0 ? null : onCopy,
                child: const Icon(CupertinoIcons.doc_on_doc),
              ),
            Expanded(
              child: Text(
                '已选择 $count 条',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            CupertinoButton(
              key: const Key('selection-forward'),
              onPressed: canForward ? onForward : null,
              child: const Icon(CupertinoIcons.arrowshape_turn_up_right),
            ),
            CupertinoButton(
              key: const Key('selection-delete'),
              onPressed: count == 0 ? null : onDelete,
              child: const Icon(
                CupertinoIcons.delete,
                color: CupertinoColors.systemRed,
              ),
            ),
          ],
        ),
      );
}
